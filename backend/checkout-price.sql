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
