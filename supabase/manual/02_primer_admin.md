# Crear la primera cuenta de equipo en un proyecto nuevo

Las altas por fuera de la app están bloqueadas (lista de permitidos). Para el primer admin:

1. En Supabase › SQL Editor:
   ```sql
   insert into private.signup_allow(email) values ('miusuario@app.lamurallaproject.es');
   ```
2. En Supabase › Authentication › Users › "Add user": email `miusuario@app.lamurallaproject.es`, contraseña, marcar "Auto confirm".
3. En SQL Editor (cambia el email):
   ```sql
   insert into public.profiles(id, role, username, business, contact, price)
   select id, 'admin', 'miusuario', 'Equipo La Muralla', 'Tu nombre', 0 from auth.users where email = 'miusuario@app.lamurallaproject.es';
   ```
4. Entra en la app con el usuario `miusuario`. El resto de cuentas de equipo se crean desde Ajustes › Equipo.
