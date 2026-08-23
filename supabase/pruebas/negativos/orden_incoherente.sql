-- El perfil laurel deja de ser el más antiguo: el color y la antigüedad ya no
-- coinciden con lo que decía el inventario. El backfill debe abortar en vez
-- de fiarse de una de las dos vías.
update public.profiles
   set created_at = (select max(created_at) from public.profiles) + interval '1 day'
 where color = 'laurel';
