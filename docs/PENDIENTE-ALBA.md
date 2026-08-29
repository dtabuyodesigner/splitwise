# Pendiente para activar la instancia de Alba

Estado a 29 de agosto de 2026. Cuando esté todo hecho, borra este archivo.

**Nada está publicado todavía.** `main` sigue en `cdf2b45d`. El trabajo está
en la rama `instancia/alba`, commit `b97e79ad`, con CI en verde.
`https://dtabuyodesigner.github.io/splitwise/alba/` da 404 ahora mismo.

Datos del proyecto de Alba, ya escritos en `instancias/registro.js`:

```
Project URL : https://wspcrnqdoucohattians.supabase.co
Project ref : wspcrnqdoucohattians
```

---

## 1. Aplicar las migraciones al proyecto de Alba

**Es lo que de verdad bloquea.** Sin esto `/alba/` carga y enseña la pantalla
de acceso, pero registrarse falla: en ese proyecto no existen ni las tablas
ni el trigger que crea el perfil.

La URL de conexión está en Supabase → **Project settings → Database →
Connection string → URI**.

```bash
git fetch origin
git checkout instancia/alba

# Primero en seco, para ver qué haría y en qué orden.
supabase/aplicar-migraciones.sh "postgresql://...wspcrnqdoucohattians..." --dry-run

# Y de verdad.
supabase/aplicar-migraciones.sh "postgresql://...wspcrnqdoucohattians..."
```

El script aplica los nueve pasos en el orden correcto y con los límites
transaccionales correctos. Lo importante que hace por ti: `0002` y `0002b`
van en **una sola transacción** (si el backfill aborta, `group_members` no
llega a existir; aplicarlos por separado deja la tabla creada y vacía, y en
ese estado la app no enseña ningún grupo). Y el orden es explícito, no
depende del `locale`: hay configuraciones donde `0002b_` se ordena antes que
`0002_group_members`.

Son idempotentes: si algo se queda a medias, se reejecuta sin miedo.

Después, en Supabase → **Authentication → Providers**: deja activo *Email*.
Si quieres que solo entre gente invitada, desactiva *Enable sign ups* y da de
alta las cuentas desde *Users → Add user*.

---

## 2. Subir los dos workflows que faltan

No llegaron al commit porque el token no tenía permiso **Workflows**. Están
en el tgz `splitwise-v18-multi-instancia.tgz`.

```bash
# Copia estos dos desde el tgz al repo:
#   .github/workflows/ci.yml               (modificado)
#   .github/workflows/nueva-instancia.yml  (nuevo)

git add .github/workflows/
git commit -m "CI: comprobar todas las instancias y el flujo de creación"
git push origin instancia/alba
```

Qué aportan:

- **`ci.yml`**: comprueba la coherencia de *todas* las instancias, valida
  cada `manifest.json` y falla si alguien edita a mano un archivo generado
  (`instancias.mjs --check` + `git diff`).
- **`nueva-instancia.yml`**: crear una instancia nueva desde el móvil, sin
  ordenador. Actions → *Nueva instancia* → Run workflow. Registra, genera,
  prueba y abre un PR. Rechaza una clave `service_role` descodificando el JWT.

Sin ellos CI sigue pasando, pero sin las comprobaciones nuevas y sin el flujo
de creación.

---

## 3. Fusionar a main

```bash
npm test && npm run verificar && npm run instancias:check
```

Deben salir 208 pruebas en verde, `v18 · 2 instancia(s) · 18 módulos`, e
instancias al día. Luego abre el PR desde
`github.com/dtabuyodesigner/splitwise/compare/main...instancia/alba` y
fusiona.

Pages publica en un par de minutos. **Fusionar a `main` publica**: no hay
workflow de despliegue.

---

## 4. Comprobar que no se ha roto lo vuestro

La instancia `dani` pasa a v18. Los prefijos de almacenamiento y de caché no
cambian a propósito, para no perder la cola pendiente ni duplicaros el icono.
Aun así, después de fusionar:

- [ ] Abre la vuestra. La cabecera debe poner `v18`.
- [ ] El saldo del grupo es el mismo de antes.
- [ ] Los grupos siguen todos ahí.
- [ ] Añade un gasto de prueba y bórralo.

Si algo va mal, revertir es devolver `main` a `cdf2b45d`.

---

## 5. Alba

- [ ] Que abra `https://dtabuyodesigner.github.io/splitwise/alba/`.
- [ ] Que la añada a la pantalla de inicio (Compartir → Añadir a inicio).
- [ ] Que se registre con su correo.
- [ ] Que cree un grupo desde la hoja **Grupos**.

Su instancia muestra `v18 · alba` junto a la versión, para distinguirla de la
vuestra si acabáis con las dos en el mismo móvil.

---

## 6. Después

- [ ] **Revoca el token** `github_pat_11APSHWQA0...`. Tiene admin sobre el
      repo y quedó escrito en una conversación. Crea otro con Contents,
      Workflows y Pull requests, que es lo mínimo para esto.
- [ ] Borra este archivo.

---

## Aviso sobre Supabase

El plan gratuito permite **dos proyectos activos por organización**. Con
`cmkzcvfjgrgxwqjimtxa` (Dani y Pilar) y `wspcrnqdoucohattians` (Alba) los
agotas. Para una tercera instancia habrá que pagar, usar otra organización, o
replantear el modelo. Está comentado en `docs/MULTI-INSTANCIA.md` §7.
