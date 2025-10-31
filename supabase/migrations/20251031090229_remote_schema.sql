drop extension if exists "pg_net";


  create table "public"."tasks" (
    "id" uuid not null default gen_random_uuid(),
    "created_at" timestamp with time zone not null default now(),
    "type" text,
    "title" text,
    "description" text,
    "is_completed" boolean default false,
    "user_id" uuid
      );



  create table "public"."users" (
    "id" uuid not null default auth.uid(),
    "created_at" timestamp with time zone not null default now(),
    "name" text,
    "email" text,
    "is_deleted" boolean,
    "token" text,
    "last_active" date
      );


alter table "public"."users" enable row level security;

CREATE UNIQUE INDEX tasks_pkey ON public.tasks USING btree (id);

CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id);

alter table "public"."tasks" add constraint "tasks_pkey" PRIMARY KEY using index "tasks_pkey";

alter table "public"."users" add constraint "users_pkey" PRIMARY KEY using index "users_pkey";

alter table "public"."tasks" add constraint "tasks_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) not valid;

alter table "public"."tasks" validate constraint "tasks_user_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.search_tasks(search_term text)
 RETURNS TABLE(id uuid, created_at timestamp with time zone, type text, title text, description text, is_completed boolean, user_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY 
    SELECT 
        tasks.id,
        tasks.created_at,
        tasks.type,
        tasks.title,
        tasks.description,
        tasks.is_completed,
        tasks.user_id
    FROM tasks
    WHERE 
        -- Case-insensitive partial matching across multiple columns
        lower(tasks.title) LIKE '%' || lower(search_term) || '%' OR
        lower(tasks.description) LIKE '%' || lower(search_term) || '%' OR
        lower(tasks.type) LIKE '%' || lower(search_term) || '%';
END;
$function$
;

grant delete on table "public"."tasks" to "anon";

grant insert on table "public"."tasks" to "anon";

grant references on table "public"."tasks" to "anon";

grant select on table "public"."tasks" to "anon";

grant trigger on table "public"."tasks" to "anon";

grant truncate on table "public"."tasks" to "anon";

grant update on table "public"."tasks" to "anon";

grant delete on table "public"."tasks" to "authenticated";

grant insert on table "public"."tasks" to "authenticated";

grant references on table "public"."tasks" to "authenticated";

grant select on table "public"."tasks" to "authenticated";

grant trigger on table "public"."tasks" to "authenticated";

grant truncate on table "public"."tasks" to "authenticated";

grant update on table "public"."tasks" to "authenticated";

grant delete on table "public"."tasks" to "service_role";

grant insert on table "public"."tasks" to "service_role";

grant references on table "public"."tasks" to "service_role";

grant select on table "public"."tasks" to "service_role";

grant trigger on table "public"."tasks" to "service_role";

grant truncate on table "public"."tasks" to "service_role";

grant update on table "public"."tasks" to "service_role";

grant delete on table "public"."users" to "anon";

grant insert on table "public"."users" to "anon";

grant references on table "public"."users" to "anon";

grant select on table "public"."users" to "anon";

grant trigger on table "public"."users" to "anon";

grant truncate on table "public"."users" to "anon";

grant update on table "public"."users" to "anon";

grant delete on table "public"."users" to "authenticated";

grant insert on table "public"."users" to "authenticated";

grant references on table "public"."users" to "authenticated";

grant select on table "public"."users" to "authenticated";

grant trigger on table "public"."users" to "authenticated";

grant truncate on table "public"."users" to "authenticated";

grant update on table "public"."users" to "authenticated";

grant delete on table "public"."users" to "service_role";

grant insert on table "public"."users" to "service_role";

grant references on table "public"."users" to "service_role";

grant select on table "public"."users" to "service_role";

grant trigger on table "public"."users" to "service_role";

grant truncate on table "public"."users" to "service_role";

grant update on table "public"."users" to "service_role";


  create policy "Policy with security definer functions"
  on "public"."tasks"
  as permissive
  for all
  to authenticated
using (true);



  create policy "Policy with security definer functions"
  on "public"."users"
  as permissive
  for all
  to public
using (true);



