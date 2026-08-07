-- As funções do painel precisam ser chamáveis por quem está logado (a autorização
-- está dentro delas), mas não há motivo para expô-las a quem nem entrou.
--
-- Depois disto o get_advisors mantém três avisos de
-- "Signed-In Users Can Execute SECURITY DEFINER Function", um por função.
-- São intencionais: silenciá-los exigiria tornar o painel inoperante.
revoke all on function public.listar_usuarios()        from public, anon;
revoke all on function public.promover_admin(text)     from public, anon;
revoke all on function public.rebaixar_admin(uuid)     from public, anon;

grant execute on function public.listar_usuarios()     to authenticated;
grant execute on function public.promover_admin(text)  to authenticated;
grant execute on function public.rebaixar_admin(uuid)  to authenticated;
