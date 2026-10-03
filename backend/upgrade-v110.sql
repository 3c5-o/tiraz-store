begin;
alter table public.orders add column if not exists user_id uuid references auth.users(id);
alter table public.orders add column if not exists request_id uuid unique;
alter table public.orders add column if not exists request_hash text;
alter table public.orders add column if not exists push_alias text;
alter table public.product_media add column if not exists content_type text;
alter table public.product_media add column if not exists file_size bigint;
alter table public.product_media add column if not exists file_name text;
alter table public.reviews add column if not exists user_id uuid references auth.users(id);
alter table public.profiles add column if not exists addresses jsonb not null default '[]';
create table if not exists public.audit_log(id bigint generated always as identity primary key,user_id uuid,action text not null,entity_id text,details jsonb not null default '{}',created_at timestamptz not null default now());
create table if not exists public.notification_outbox(id uuid primary key default gen_random_uuid(),order_id uuid references public.orders(id),kind text not null,version text not null default 'new',state text not null default 'pending',attempts int not null default 0,next_attempt timestamptz not null default now(),last_error text,created_at timestamptz not null default now(),unique(order_id,kind,version));
create table if not exists public.api_limits(key text primary key,hits int not null,window_at timestamptz not null);
alter table public.audit_log enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.api_limits enable row level security;
create index if not exists orders_user_created on public.orders(user_id,created_at desc);
create index if not exists orders_status_created on public.orders(status,created_at desc);
create index if not exists outbox_ready on public.notification_outbox(next_attempt) where state in ('pending','failed');
create unique index if not exists reviews_user_product on public.reviews(user_id,product_id) where user_id is not null;
create or replace function public.has_permission(p_permission text) returns boolean language sql stable security definer set search_path=public as $$
select exists(select 1 from admin_users where user_id=auth.uid() and active and (role='owner' or (role='admin' and p_permission in ('content','orders','settings','audit')) or role=p_permission));
$$;
revoke all on function public.has_permission(text) from public;
grant execute on function public.has_permission(text) to anon,authenticated;
-- Replace broad policies with permissions enforced in the database.
do $$declare p record; t text; permission text;begin
 for p in select policyname,tablename from pg_policies where schemaname='public' and (policyname like 'admins %' or policyname='admin users self read') loop
 execute format('drop policy %I on public.%I',p.policyname,p.tablename);end loop;
 create policy admin_self_read on public.admin_users for select to authenticated using(user_id=auth.uid() or has_permission('owner'));
 for t,permission in select * from (values ('products','content'),('product_variants','content'),('product_media','content'),('boxes','content'),('categories','content'),('brands','content'),('banners','content'),('reviews','content'),('app_settings','settings')) x loop
 execute format('create policy role_manage on public.%I for all to authenticated using(public.has_permission(%L)) with check(public.has_permission(%L))',t,permission,permission);end loop;
 create policy role_order_read on public.orders for select to authenticated using(has_permission('orders') or user_id=auth.uid());
 create policy role_items_read on public.order_items for select to authenticated using(has_permission('orders') or exists(select 1 from orders o where o.id=order_id and o.user_id=auth.uid()));
 create policy role_history_read on public.order_status_history for select to authenticated using(has_permission('orders') or exists(select 1 from orders o where o.id=order_id and o.user_id=auth.uid()));
 create policy owner_channels on public.integration_channels for all to authenticated using(has_permission('owner')) with check(has_permission('owner'));
 create policy audit_read on public.audit_log for select to authenticated using(has_permission('audit'));
 create policy outbox_read on public.notification_outbox for select to authenticated using(has_permission('owner'));
end$$;
revoke all on public.integration_credentials,public.api_limits from anon,authenticated;
revoke insert,update,delete on public.admin_users,public.orders,public.order_items,public.order_status_history,public.audit_log,public.notification_outbox from anon,authenticated;
grant select on public.audit_log,public.notification_outbox to authenticated;
revoke all on function public.claim_first_owner() from public,anon,authenticated;
create or replace function public.consume_api_limit(p_key text,p_limit int,p_seconds int) returns boolean language plpgsql security definer set search_path=public as $$
declare n int;begin
 insert into api_limits(key,hits,window_at) values(p_key,1,now()) on conflict(key) do update set hits=case when api_limits.window_at<now()-make_interval(secs=>p_seconds) then 1 else api_limits.hits+1 end,window_at=case when api_limits.window_at<now()-make_interval(secs=>p_seconds) then now() else api_limits.window_at end returning hits into n;
 return n<=p_limit;end$$;
revoke all on function public.consume_api_limit(text,int,int) from public,anon,authenticated;
grant execute on function public.consume_api_limit(text,int,int) to service_role;
create or replace function public.create_order(p_customer jsonb,p_items jsonb,p_notes text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders; item jsonb; p products; v product_variants; b boxes; qty int; v_subtotal bigint:=0; v_extras bigint:=0; fee bigint:=0; request uuid; fingerprint text; phone_digits text; begin
 request:=(p_customer->>'_request_id')::uuid;
 if request is null then raise exception 'Request ID required';end if;
 perform pg_advisory_xact_lock(hashtextextended(request::text,0));
 fingerprint:=md5((p_customer-'_request_id'-'_push_alias')::text||p_items::text||coalesce(p_notes,''));
 select * into o from orders where request_id=request;
 if found then if o.request_hash<>fingerprint then raise exception 'Request conflict';end if;return jsonb_build_object('order_id',o.id,'order_number',o.order_number,'total',o.total,'currency',o.currency,'duplicate',true);end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'Cart is empty';end if;
 if coalesce(trim(p_customer->>'customer_name'),'')='' or coalesce(trim(p_customer->>'province'),'')='' or coalesce(trim(p_customer->>'area'),'')='' then raise exception 'Missing required customer information';end if;
 if length(p_customer->>'customer_name')>100 or length(p_customer->>'province')>100 or length(p_customer->>'area')>140 or length(coalesce(p_customer->>'address',''))>500 or length(coalesce(p_customer->>'landmark',''))>200 or length(coalesce(p_notes,''))>1000 then raise exception 'Input too long';end if;
 phone_digits:=regexp_replace(p_customer->>'phone','[^0-9]','','g');
 if phone_digits is null or length(phone_digits)<10 or length(phone_digits)>15 then raise exception 'Invalid phone';end if;
 perform pg_advisory_xact_lock(hashtextextended(phone_digits,1));
 if (select count(*) from orders where regexp_replace(phone,'[^0-9]','','g')=phone_digits and created_at>now()-interval '10 minutes')>=5 then raise exception 'Too many recent orders';end if;
 select coalesce((value->'province_fees'->>(p_customer->>'province'))::bigint,(value->>'default_fee')::bigint,0) into fee from app_settings where key='delivery';
 insert into orders(customer_name,phone,alt_phone,province,area,landmark,address,notes,delivery_fee,user_id,request_id,request_hash,push_alias) values(trim(p_customer->>'customer_name'),phone_digits,nullif(p_customer->>'alt_phone',''),trim(p_customer->>'province'),trim(p_customer->>'area'),nullif(p_customer->>'landmark',''),nullif(p_customer->>'address',''),nullif(p_notes,''),greatest(coalesce(fee,0),0),nullif(p_customer->>'_user_id','')::uuid,request,fingerprint,nullif(p_customer->>'_push_alias','')) returning * into o;
 for item in select value from jsonb_array_elements(p_items) order by value->>'variant_id',value->>'box_id' loop
 qty:=(item->>'quantity')::int;if qty is null or qty<1 or qty>20 then raise exception 'Invalid quantity';end if;
 select * into p from products where id=(item->>'product_id')::uuid and published for share;if not found then raise exception 'Product unavailable';end if;
 select * into v from product_variants where id=nullif(item->>'variant_id','')::uuid and product_id=p.id and active for update;
 if not found then raise exception 'Variant unavailable';end if;
 if v.stock<qty then raise exception 'Insufficient stock';end if;
 update product_variants set stock=stock-qty where id=v.id;
 b:=null;
 if nullif(item->>'box_id','') is not null then
 select * into b from boxes where id=(item->>'box_id')::uuid and active for update;
 if not found or b.stock<qty then raise exception 'Box unavailable';end if;
 update boxes set stock=stock-qty where id=b.id;end if;
 insert into order_items(order_id,product_id,variant_id,product_name_snapshot,variant_name_snapshot,unit_price,quantity,box_id,box_name_snapshot,box_price_snapshot,line_total) values(o.id,p.id,v.id,p.name_ar,v.name_ar,coalesce(v.price_override,p.base_price),qty,b.id,b.name_ar,coalesce(b.price,0),(coalesce(v.price_override,p.base_price)+coalesce(b.price,0))*qty);
 v_subtotal:=v_subtotal+coalesce(v.price_override,p.base_price)*qty;v_extras:=v_extras+coalesce(b.price,0)*qty;
 end loop;
 if nullif(p_customer->>'_expected_total','') is not null and (p_customer->>'_expected_total')::bigint<>v_subtotal+v_extras+o.delivery_fee-o.discount then raise exception 'Price changed';end if;
 update orders set subtotal=v_subtotal,extras=v_extras,total=v_subtotal+v_extras+delivery_fee-discount where id=o.id returning * into o;
 insert into order_status_history(order_id,status,note) values(o.id,'new','تم استلام الطلب');
 insert into notification_outbox(order_id,kind) values(o.id,'telegram_order'),(o.id,'admin_push') on conflict do nothing;
 return jsonb_build_object('order_id',o.id,'order_number',o.order_number,'total',o.total,'currency',o.currency);
end$$;
revoke all on function public.create_order(jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_order(jsonb,jsonb,text) to service_role;
create or replace function public.update_order_status(p_order_id uuid,p_status text,p_note text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders; item record; allowed text[];begin
 if not has_permission('orders') then raise exception 'Forbidden';end if;
 select * into o from orders where id=p_order_id for update;if not found then raise exception 'Order not found';end if;
 if o.status=p_status then return jsonb_build_object('ok',true,'status',p_status);end if;
 allowed:=case o.status when 'new' then array['confirmed','cancelled','rejected'] when 'confirmed' then array['preparing','cancelled'] when 'preparing' then array['shipped','cancelled'] when 'shipped' then array['delivered','cancelled'] else array[]::text[] end;
 if not p_status=any(allowed) then raise exception 'Invalid status transition';end if;
 if p_status in ('cancelled','rejected') then
 for item in select variant_id,sum(quantity)::int qty from order_items where order_id=o.id and variant_id is not null group by variant_id loop update product_variants set stock=stock+item.qty where id=item.variant_id;end loop;
 -- Legacy orders used one box per line; new orders use one box per item.
 for item in select box_id,sum(case when o.request_id is null then 1 else quantity end)::int qty from order_items where order_id=o.id and box_id is not null group by box_id loop update boxes set stock=stock+item.qty where id=item.box_id;end loop;
 end if;
 update orders set status=p_status where id=o.id;
 insert into order_status_history(order_id,status,note,changed_by) values(o.id,p_status,left(p_note,500),auth.uid());
 insert into audit_log(user_id,action,entity_id,details) values(auth.uid(),'order_status',o.id::text,jsonb_build_object('from',o.status,'to',p_status));
 if o.push_alias is not null then insert into notification_outbox(order_id,kind,version) values(o.id,'customer_push',p_status) on conflict do nothing;end if;
 return jsonb_build_object('ok',true,'status',p_status);end$$;
revoke all on function public.update_order_status(uuid,text,text) from public,anon;
grant execute on function public.update_order_status(uuid,text,text) to authenticated;
create or replace function public.track_order(p_order_number text,p_phone text) returns jsonb language sql stable security definer set search_path=public as $$
select jsonb_build_object('order_number',o.order_number,'status',o.status,'total',o.total,'currency',o.currency,'created_at',o.created_at,'history',coalesce((select jsonb_agg(jsonb_build_object('status',h.status,'created_at',h.created_at) order by h.created_at) from order_status_history h where h.order_id=o.id),'[]')) from orders o where upper(o.order_number)=upper(trim(p_order_number)) and regexp_replace(o.phone,'[^0-9]','','g')=regexp_replace(p_phone,'[^0-9]','','g') limit 1;
$$;
revoke all on function public.track_order(text,text) from public,anon,authenticated;
grant execute on function public.track_order(text,text) to service_role;
create or replace function public.save_product(p_data jsonb,p_variants jsonb) returns uuid language plpgsql security definer set search_path=public as $$
declare v_product_id uuid; v_brand_id uuid; item jsonb; vid uuid; oldv product_variants;begin
 if not has_permission('content') then raise exception 'Forbidden';end if;
 if trim(coalesce(p_data->>'name_ar',''))='' or (p_data->>'base_price')::bigint<0 or jsonb_array_length(p_variants)=0 then raise exception 'Invalid product';end if;
 if nullif(trim(p_data->>'brand'),'') is not null then
 select id into v_brand_id from brands where name=trim(p_data->>'brand');
 if v_brand_id is null then insert into brands(name,slug) values(trim(p_data->>'brand'),substr(md5(trim(p_data->>'brand')),1,16)) returning id into v_brand_id;end if;end if;
 v_product_id:=nullif(p_data->>'id','')::uuid;
 if v_product_id is null then
 insert into products(name_ar,name_en,slug,brand_id,category_id,gender,style,description_ar,base_price,compare_at_price,published,featured) values(trim(p_data->>'name_ar'),nullif(p_data->>'name_en',''),gen_random_uuid()::text,v_brand_id,(p_data->>'category_id')::uuid,coalesce(p_data->>'gender','unisex'),coalesce(p_data->>'style','modern'),p_data->>'description_ar',(p_data->>'base_price')::bigint,nullif(p_data->>'compare_at_price','')::bigint,false,coalesce((p_data->>'featured')::boolean,false)) returning id into v_product_id;
 else
 perform 1 from products where id=v_product_id for update;if not found then raise exception 'Product unavailable';end if;
 update products set name_ar=trim(p_data->>'name_ar'),name_en=nullif(p_data->>'name_en',''),brand_id=v_brand_id,category_id=(p_data->>'category_id')::uuid,gender=p_data->>'gender',style=p_data->>'style',description_ar=p_data->>'description_ar',base_price=(p_data->>'base_price')::bigint,compare_at_price=nullif(p_data->>'compare_at_price','')::bigint,featured=coalesce((p_data->>'featured')::boolean,false) where id=v_product_id;
 end if;
 for item in select value from jsonb_array_elements(p_variants) loop
 if (item->>'stock')::int<0 or coalesce(nullif(item->>'price_override','')::bigint,0)<0 then raise exception 'Invalid stock';end if;
 vid:=nullif(item->>'id','')::uuid;
 if vid is null then insert into product_variants(product_id,name_ar,color,sku,stock,price_override,low_stock_limit,active) values(v_product_id,coalesce(nullif(item->>'name_ar',''),'الافتراضي'),item->>'name_ar',nullif(item->>'sku',''),(item->>'stock')::int,nullif(item->>'price_override','')::bigint,coalesce((item->>'low_stock_limit')::int,3),coalesce((item->>'active')::boolean,true));
 else select * into oldv from product_variants where id=vid and product_id=v_product_id for update;if not found then raise exception 'Variant unavailable';end if;
 if item ? 'expected_stock' and oldv.stock<>(item->>'expected_stock')::int then raise exception 'Stock changed';end if;
 update product_variants set name_ar=item->>'name_ar',color=item->>'name_ar',sku=nullif(item->>'sku',''),stock=(item->>'stock')::int,price_override=nullif(item->>'price_override','')::bigint,low_stock_limit=coalesce((item->>'low_stock_limit')::int,3),active=coalesce((item->>'active')::boolean,true) where id=vid;end if;
 end loop;
 insert into audit_log(user_id,action,entity_id) values(auth.uid(),'save_product',v_product_id::text);
 return v_product_id;end$$;
revoke all on function public.save_product(jsonb,jsonb) from public,anon;
grant execute on function public.save_product(jsonb,jsonb) to authenticated;
create or replace function public.submit_review(p_product_id uuid,p_rating int,p_comment text) returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or p_rating<1 or p_rating>5 or length(p_comment)>1000 then raise exception 'Invalid review';end if;
 if not exists(select 1 from orders o join order_items i on i.order_id=o.id where o.user_id=auth.uid() and o.status='delivered' and i.product_id=p_product_id) then raise exception 'Purchase required';end if;
 insert into reviews(product_id,user_id,customer_name,rating,comment,approved) values(p_product_id,auth.uid(),coalesce((select full_name from profiles where user_id=auth.uid()),'زبون طراز'),p_rating,p_comment,false) on conflict(user_id,product_id) where user_id is not null do update set rating=excluded.rating,comment=excluded.comment,approved=false;end$$;
revoke all on function public.submit_review(uuid,int,text) from public,anon;
grant execute on function public.submit_review(uuid,int,text) to authenticated;
commit;
