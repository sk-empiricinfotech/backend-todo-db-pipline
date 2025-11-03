alter table "public"."assigned_role" add column "text_field1" text;

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


