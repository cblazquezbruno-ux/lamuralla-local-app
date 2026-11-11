create policy lm_logos_sel on storage.objects for select to authenticated using (bucket_id = 'logos');
create policy lm_files_upd on storage.objects for update to authenticated using (bucket_id = 'files' and public.is_admin()) with check (bucket_id = 'files' and public.is_admin());
