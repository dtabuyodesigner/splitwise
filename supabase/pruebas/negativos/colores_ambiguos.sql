-- Los dos perfiles con el mismo color: ya no se puede distinguir a Dani de
-- Pilar por color, así que el backfill no debe elegir por su cuenta.
update public.profiles set color = 'laurel';
