begin;
do $$
declare owner_id uuid;pid uuid;vid uuid;bid uuid;request uuid:=gen_random_uuid();customer jsonb;items jsonb;a jsonb;b jsonb;v_stock int;begin
select user_id into owner_id from public.admin_users where role='owner' and active limit 1;
perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated')::text,true);
pid:=public.save_product(jsonb_build_object('name_ar','اختبار آلي مؤقت','base_price',1000,'category_id',(select id from categories limit 1),'gender','unisex','style','modern'),jsonb_build_array(jsonb_build_object('name_ar','فضي','stock',5,'active',true)));
select id into vid from product_variants where product_id=pid;
update products set published=true where id=pid;
bid:=public.save_box(jsonb_build_object('name_ar','علبة اختبار','price',100,'stock',5,'active',true));
customer:=jsonb_build_object('customer_name','اختبار مؤقت','phone','07701234567','province','بغداد','area','اختبار','_request_id',request,'_user_id',owner_id);
items:=jsonb_build_array(jsonb_build_object('product_id',pid,'variant_id',vid,'box_id',bid,'quantity',2));
a:=public.create_order(customer,items);b:=public.create_order(customer,items);
if a->>'order_id'<>b->>'order_id' then raise exception 'Duplicate order regression';end if;
select stock into v_stock from product_variants where id=vid;
if v_stock<>3 then raise exception 'Variant stock regression';end if;
if (select stock from boxes where id=bid)<>3 then raise exception 'Box quantity regression';end if;
begin perform public.create_order(customer||jsonb_build_object('_request_id',gen_random_uuid()),jsonb_build_array(jsonb_build_object('product_id',pid,'quantity',1)));raise exception 'Variant bypass regression';exception when others then if sqlerrm<>'Variant unavailable' then raise;end if;end;
begin perform public.create_order(customer||jsonb_build_object('_request_id',gen_random_uuid()),jsonb_build_array(jsonb_build_object('product_id',pid,'variant_id',vid,'quantity',9)));raise exception 'Oversell regression';exception when others then if sqlerrm<>'Insufficient stock' then raise;end if;end;
perform public.update_order_status((a->>'order_id')::uuid,'cancelled','اختبار');
perform public.update_order_status((a->>'order_id')::uuid,'cancelled','اختبار مكرر');
if (select stock from product_variants where id=vid)<>5 or (select stock from boxes where id=bid)<>5 then raise exception 'Restore stock regression';end if;
perform set_config('request.jwt.claims',jsonb_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
if public.has_permission('content') or public.has_permission('orders') or public.has_permission('owner') then raise exception 'Unauthorized permission regression';end if;
begin perform public.update_order_status((a->>'order_id')::uuid,'delivered','');raise exception 'Unauthorized order regression';exception when others then if sqlerrm<>'Forbidden' then raise;end if;end;
raise notice 'PASS: products, variants, duplicate orders, box quantity, stock restoration, and authorization';
end$$;
rollback;
