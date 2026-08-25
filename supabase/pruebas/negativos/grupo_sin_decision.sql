-- Un cuarto grupo histórico que nadie ha decidido. El backfill debe abortar:
-- migrar dejándolo sin miembros lo haría desaparecer para todo el mundo.
insert into public.groups (id, name)
values ('aaaaaaaa-0000-0000-0000-0000000000e0', 'Un grupo nuevo sin decidir');
