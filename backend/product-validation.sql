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
