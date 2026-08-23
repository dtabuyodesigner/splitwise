-- Una tercera cuenta. El backfill describe la situación de dos personas:
-- con tres, la pertenencia hay que volver a decidirla.
insert into auth.users (id, email, raw_user_meta_data)
values ('99999999-9999-9999-9999-999999999999', 'tercero@ejemplo.test',
        '{"display_name":"Tercero","color":"otro"}');
