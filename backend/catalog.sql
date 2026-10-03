CREATE OR REPLACE FUNCTION public.list_store_products()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'created_at',p.created_at,
      'name_ar', p.name_ar,
      'name_en', p.name_en,
      'slug', p.slug,
      'description_ar', p.description_ar,
      'base_price', p.base_price,
      'compare_at_price', p.compare_at_price,
      'currency', p.currency,
      'gender', p.gender,
      'style', p.style,
      'featured', p.featured,
      'brand', case when b.id is null then null else jsonb_build_object('name',b.name) end,
      'category', case when c.id is null then null else jsonb_build_object('slug',c.slug,'name_ar',c.name_ar) end,
      'product_variants', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',v.id,'name_ar',v.name_ar,'color',v.color,
          'price_override',v.price_override,'stock',v.stock,'active',v.active
        ) order by v.created_at)
        from public.product_variants v
        where v.product_id=p.id and v.active=true
      ), '[]'::jsonb),
      'product_media', coalesce((
        select jsonb_agg(jsonb_build_object(
          'variant_id',m.variant_id,'id',m.id,'proxy_key',m.proxy_key,'media_type',m.media_type,
          'sort_order',m.sort_order,'is_cover',m.is_cover
        ) order by m.is_cover desc, m.sort_order, m.created_at)
        from public.product_media m
        where m.product_id=p.id
      ), '[]'::jsonb)
    )
    order by p.sort_order, p.created_at desc
  ), '[]'::jsonb)
  from public.products p
  left join public.brands b on b.id=p.brand_id
  left join public.categories c on c.id=p.category_id
  where p.published=true;
$function$

drop policy if exists "profiles own select" on public.profiles;
create policy profiles_own_or_orders on public.profiles for select to authenticated using(user_id=auth.uid() or has_permission('orders'));

