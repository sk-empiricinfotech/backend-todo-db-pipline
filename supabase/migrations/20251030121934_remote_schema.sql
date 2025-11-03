SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;
COMMENT ON SCHEMA "public" IS 'standard public schema';
CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "pgsodium";
CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";
CREATE TYPE "public"."account_type" AS ENUM (
    'super_admin',
    'admin',
    'coordinator',
    'user',
    'customer',
    'sub_customer'
);
ALTER TYPE "public"."account_type" OWNER TO "postgres";
COMMENT ON TYPE "public"."account_type" IS 'Used to know user account type like is super admin, admin or user.';
CREATE TYPE "public"."booking_status" AS ENUM (
    'pending',
    'confirmed',
    'rejected',
    'cancelled',
    'completed',
    'accepted'
);
ALTER TYPE "public"."booking_status" OWNER TO "postgres";
CREATE TYPE "public"."customer_status" AS ENUM (
    'option',
    'confirmed',
    'cancelled',
    'expired'
);
ALTER TYPE "public"."customer_status" OWNER TO "postgres";
CREATE TYPE "public"."customer_type" AS ENUM (
    'travel_agencies',
    'school'
);
ALTER TYPE "public"."customer_type" OWNER TO "postgres";
CREATE TYPE "public"."feedback_status" AS ENUM (
    'pending',
    'accepted',
    'rejected'
);
ALTER TYPE "public"."feedback_status" OWNER TO "postgres";
CREATE TYPE "public"."group_status" AS ENUM (
    'pending',
    'partially_assigned',
    'family_assigned',
    'partially_confirmed',
    'family_confirmed',
    'completed',
    'expired'
);
ALTER TYPE "public"."group_status" OWNER TO "postgres";
CREATE TYPE "public"."host_preference" AS ENUM (
    'girl',
    'boy',
    'teacher_women',
    'teacher_men',
    'driver',
    'tour_guide'
);
ALTER TYPE "public"."host_preference" OWNER TO "postgres";
CREATE TYPE "public"."marital_status" AS ENUM (
    'single',
    'married',
    'divorced',
    'in_relationship',
    'widowed'
);
ALTER TYPE "public"."marital_status" OWNER TO "postgres";
CREATE TYPE "public"."meeting_point_type" AS ENUM (
    'meeting_point',
    'hospital',
    'parking'
);
ALTER TYPE "public"."meeting_point_type" OWNER TO "postgres";
CREATE TYPE "public"."verification_status" AS ENUM (
    'active',
    'panding_active',
    'pending',
    'blocked'
);
ALTER TYPE "public"."verification_status" OWNER TO "postgres";
COMMENT ON TYPE "public"."verification_status" IS 'Used to set verification status for Host Family.';
CREATE OR REPLACE FUNCTION "public"."calculate_haversine_distance"("lat1" double precision, "lng1" double precision, "lat2" double precision, "lng2" double precision) RETURNS double precision
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    earth_radius double precision := 6371; -- Earth's radius in kilometers
    dlat double precision;
    dlng double precision;
    a double precision;
    c double precision;
BEGIN
    -- Convert degrees to radians
    dlat := radians(lat2 - lat1);
    dlng := radians(lng2 - lng1);
    
    -- Haversine formula
    a := sin(dlat / 2) * sin(dlat / 2) +
         cos(radians(lat1)) * cos(radians(lat2)) *
         sin(dlng / 2) * sin(dlng / 2);
    
    c := 2 * atan2(sqrt(a), sqrt(1 - a));
    
    -- Return distance in kilometers
    RETURN earth_radius * c;
END;
$$;
ALTER FUNCTION "public"."calculate_haversine_distance"("lat1" double precision, "lng1" double precision, "lat2" double precision, "lng2" double precision) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_coodinators_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    webhook_url TEXT := 'https://ocedciqhovecfmcoklnr.supabase.co/functions/v1/coodinator_webhook';
    payload JSON;
    old_data JSON := NULL;
    new_data JSON := NULL;
BEGIN
    -- Prepare the data based on the operation
    IF TG_OP = 'DELETE' THEN
        old_data := row_to_json(OLD);
    ELSIF TG_OP = 'INSERT' THEN
        new_data := row_to_json(NEW);
    ELSIF TG_OP = 'UPDATE' THEN
        old_data := row_to_json(OLD);
        new_data := row_to_json(NEW);
    END IF;

    -- Create the payload with operation type and data
    payload := json_build_object(
        'type', TG_OP,            -- Edge function expects "type"
        'table', TG_TABLE_NAME,
        'schema', TG_TABLE_SCHEMA,
        'timestamp', extract(epoch from now()),
        'record', new_data,       -- Edge function expects "record"
        'old_record', old_data
    );

    -- Make the HTTP request to your webhook
    PERFORM
        net.http_post(
            url := webhook_url,
            headers := jsonb_build_object(
                'Content-Type', 'application/json'
            ),
            body := payload::jsonb
        );

    -- Return the appropriate record based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error but don't prevent the original operation
        RAISE WARNING 'Webhook call failed: %', SQLERRM;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;
ALTER FUNCTION "public"."call_coodinators_webhook"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_customer_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    webhook_url TEXT := 'https://ocedciqhovecfmcoklnr.supabase.co/functions/v1/customer_webhook';
    payload JSON;
    record_data JSON := NULL;
    old_record_data JSON := NULL;
BEGIN
    -- Handle UPDATE operation with special logic for active field
    IF TG_OP = 'UPDATE' THEN
        -- Check if active field changed from true to false (soft delete)
        IF OLD.active = 1 AND NEW.active = 0 THEN
            -- Send as DELETE operation
            old_record_data := row_to_json(OLD);
            record_data := NULL;
            
            payload := json_build_object(
                'type', 'DELETE',
                'table', TG_TABLE_NAME,
                'schema', TG_TABLE_SCHEMA,
                'record', record_data,
                'old_record', old_record_data
            );
            
            -- Make the HTTP request to your webhook
            PERFORM
                net.http_post(
                    url := webhook_url,
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json'
                    ),
                    body := payload::jsonb
                );
        ELSE
            -- For other updates, send normal UPDATE
            record_data := row_to_json(NEW);
            old_record_data := row_to_json(OLD);
            
            payload := json_build_object(
                'type', 'UPDATE',
                'table', TG_TABLE_NAME,
                'schema', TG_TABLE_SCHEMA,
                'record', record_data,
                'old_record', old_record_data
            );
            
            -- Make the HTTP request to your webhook
            PERFORM
                net.http_post(
                    url := webhook_url,
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json'
                    ),
                    body := payload::jsonb
                );
        END IF;
        
    ELSIF TG_OP = 'INSERT' THEN
        record_data := row_to_json(NEW);
        old_record_data := NULL;
        
        payload := json_build_object(
            'type', 'INSERT',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', old_record_data
        );
        
        -- Make the HTTP request to your webhook
        PERFORM
            net.http_post(
                url := webhook_url,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json'
                ),
                body := payload::jsonb
            );
            
    ELSIF TG_OP = 'DELETE' THEN
        old_record_data := row_to_json(OLD);
        record_data := NULL;
        
        payload := json_build_object(
            'type', 'DELETE',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', old_record_data
        );
        
        -- Make the HTTP request to your webhook
        PERFORM
            net.http_post(
                url := webhook_url,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json'
                ),
                body := payload::jsonb
            );
    END IF;

    -- Return the appropriate record based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error but don't prevent the original operation
        RAISE WARNING 'Webhook call failed: %', SQLERRM;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;
ALTER FUNCTION "public"."call_customer_webhook"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_external_webhook"("webhook_url" "text", "data_param" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  -- webhook_url TEXT := 'https://provesapi.viajescumlaude.es/SupabaseFamilyCenters.aspx';
  request_body JSONB;
  request_id BIGINT;
BEGIN
  -- Build the request body
  request_body := data_param;

  -- Queue the HTTP request (fire-and-forget)
  request_id := net.http_post(
    webhook_url,
    request_body,
    '{}'::jsonb,                             -- params
    '{"Content-Type":"application/json"}'::jsonb, -- headers
    30000                                     -- timeout in milliseconds
  );

  -- Return a structured response immediately
  RETURN jsonb_build_object(
    'success', true,
    'queued', true,
    'request_id', request_id,
    'timestamp', now(),
    'target_url', webhook_url,
    'message', 'HTTP request queued successfully; response will be processed asynchronously.'
  );
END;
$$;
ALTER FUNCTION "public"."call_external_webhook"("webhook_url" "text", "data_param" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_family_center_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    webhook_url TEXT := 'https://ocedciqhovecfmcoklnr.supabase.co/functions/v1/family_center_webhook';
    payload JSON;
    record_data JSON := NULL;
    old_record_data JSON := NULL;
BEGIN
    -- Handle UPDATE operation with special logic for active field
    IF TG_OP = 'UPDATE' THEN
        -- Check if active field changed from true to false (soft delete)
        IF OLD.active = true AND NEW.active = false THEN
            -- Send as DELETE operation
            old_record_data := row_to_json(OLD);
            record_data := NULL;
            
            payload := json_build_object(
                'type', 'DELETE',
                'table', TG_TABLE_NAME,
                'schema', TG_TABLE_SCHEMA,
                'record', record_data,
                'old_record', old_record_data
            );
            
            -- Make the HTTP request to your webhook
            PERFORM
                net.http_post(
                    url := webhook_url,
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json'
                    ),
                    body := payload::jsonb
                );
        ELSE
            -- For other updates, send normal UPDATE
            record_data := row_to_json(NEW);
            old_record_data := row_to_json(OLD);
            
            payload := json_build_object(
                'type', 'UPDATE',
                'table', TG_TABLE_NAME,
                'schema', TG_TABLE_SCHEMA,
                'record', record_data,
                'old_record', old_record_data
            );
            
            -- Make the HTTP request to your webhook
            PERFORM
                net.http_post(
                    url := webhook_url,
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json'
                    ),
                    body := payload::jsonb
                );
        END IF;
        
    ELSIF TG_OP = 'INSERT' THEN
        record_data := row_to_json(NEW);
        old_record_data := NULL;
        
        payload := json_build_object(
            'type', 'INSERT',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', old_record_data
        );
        
        -- Make the HTTP request to your webhook
        PERFORM
            net.http_post(
                url := webhook_url,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json'
                ),
                body := payload::jsonb
            );
            
    ELSIF TG_OP = 'DELETE' THEN
        old_record_data := row_to_json(OLD);
        record_data := NULL;
        
        payload := json_build_object(
            'type', 'DELETE',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', old_record_data
        );
        
        -- Make the HTTP request to your webhook
        PERFORM
            net.http_post(
                url := webhook_url,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json'
                ),
                body := payload::jsonb
            );
    END IF;

    -- Return the appropriate record based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error but don't prevent the original operation
        RAISE WARNING 'Webhook call failed: %', SQLERRM;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;
ALTER FUNCTION "public"."call_family_center_webhook"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_host_family_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    webhook_url TEXT := 'https://ocedciqhovecfmcoklnr.supabase.co/functions/v1/hostFamily_webhhok';
    payload JSON;
    record_data JSON := NULL;
    old_record_data JSON := NULL;
    is_web BOOLEAN := FALSE;
BEGIN
    -- Determine is_web value depending on operation
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        is_web := NEW.is_web;
    ELSE -- DELETE
        is_web := OLD.is_web;
    END IF;

    -- Only proceed if is_web = true
    IF NOT is_web THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
    END IF;

    -- Handle UPDATE operation with special logic for active field
    IF TG_OP = 'UPDATE' THEN
        IF OLD.active = 1 AND NEW.active = 0 THEN
            old_record_data := row_to_json(OLD);
            record_data := NULL;

            payload := json_build_object(
                'type', 'DELETE',
                'table', TG_TABLE_NAME,
                'schema', TG_TABLE_SCHEMA,
                'record', record_data,
                'old_record', old_record_data
            );
        ELSE
            record_data := row_to_json(NEW);
            old_record_data := row_to_json(OLD);

            payload := json_build_object(
                'type', 'UPDATE',
                'table', TG_TABLE_NAME,
                'schema', TG_TABLE_SCHEMA,
                'record', record_data,
                'old_record', old_record_data
            );
        END IF;

        PERFORM net.http_post(
            url := webhook_url,
            headers := jsonb_build_object('Content-Type', 'application/json'),
            body := payload::jsonb
        );

    ELSIF TG_OP = 'INSERT' THEN
        record_data := row_to_json(NEW);

        payload := json_build_object(
            'type', 'INSERT',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', NULL
        );

        PERFORM net.http_post(
            url := webhook_url,
            headers := jsonb_build_object('Content-Type', 'application/json'),
            body := payload::jsonb
        );

    ELSIF TG_OP = 'DELETE' THEN
        old_record_data := row_to_json(OLD);

        payload := json_build_object(
            'type', 'DELETE',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', NULL,
            'old_record', old_record_data
        );

        PERFORM net.http_post(
            url := webhook_url,
            headers := jsonb_build_object('Content-Type', 'application/json'),
            body := payload::jsonb
        );
    END IF;

    -- Return the correct record
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Webhook call failed: %', SQLERRM;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;
ALTER FUNCTION "public"."call_host_family_webhook"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_meeting_points_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    webhook_url TEXT := 'https://ocedciqhovecfmcoklnr.supabase.co/functions/v1/meeting_points_webhook';
    payload JSON;
    old_data JSON := NULL;
    new_data JSON := NULL;
BEGIN
    -- Prepare the data based on the operation
    IF TG_OP = 'DELETE' THEN
        old_data := row_to_json(OLD);
    ELSIF TG_OP = 'INSERT' THEN
        new_data := row_to_json(NEW);
    ELSIF TG_OP = 'UPDATE' THEN
        old_data := row_to_json(OLD);
        new_data := row_to_json(NEW);
    END IF;

    -- Create the payload with operation type and data
    payload := json_build_object(
        'type', TG_OP,            -- Edge function expects "type"
        'table', TG_TABLE_NAME,
        'schema', TG_TABLE_SCHEMA,
        'timestamp', extract(epoch from now()),
        'record', new_data,       -- Edge function expects "record"
        'old_record', old_data
    );

    -- Make the HTTP request to your webhook
    PERFORM
        net.http_post(
            url := webhook_url,
            headers := jsonb_build_object(
                'Content-Type', 'application/json'
            ),
            body := payload::jsonb
        );

    -- Return the appropriate record based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error but don't prevent the original operation
        RAISE WARNING 'Webhook call failed: %', SQLERRM;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;
ALTER FUNCTION "public"."call_meeting_points_webhook"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."call_option_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    webhook_url TEXT := 'https://ocedciqhovecfmcoklnr.supabase.co/functions/v1/smooth-function';
    payload JSON;
    record_data JSON := NULL;
    old_record_data JSON := NULL;
BEGIN
    IF TG_OP = 'INSERT' THEN
        record_data := row_to_json(NEW);

        payload := json_build_object(
            'type', 'INSERT',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', NULL
        );

    ELSIF TG_OP = 'UPDATE' THEN
        record_data := row_to_json(NEW);
        old_record_data := row_to_json(OLD);

        payload := json_build_object(
            'type', 'UPDATE',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', record_data,
            'old_record', old_record_data
        );

    ELSIF TG_OP = 'DELETE' THEN
        old_record_data := row_to_json(OLD);

        payload := json_build_object(
            'type', 'DELETE',
            'table', TG_TABLE_NAME,
            'schema', TG_TABLE_SCHEMA,
            'record', NULL,
            'old_record', old_record_data
        );
    END IF;

    -- Send webhook
    PERFORM
        net.http_post(
            url := webhook_url,
            headers := jsonb_build_object(
                'Content-Type', 'application/json'
            ),
            body := payload::jsonb
        );

    -- Return the appropriate record
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Webhook call failed: %', SQLERRM;
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;
ALTER FUNCTION "public"."call_option_webhook"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."get_next_master_id"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    next_id INTEGER;
BEGIN
    -- Get the current maximum id
    SELECT COALESCE(MAX(id), 0) + 1 INTO next_id FROM master;
    
    -- Return the next id
    RETURN next_id;
END;
$$;
ALTER FUNCTION "public"."get_next_master_id"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."handle_auth_user_deleted"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$BEGIN
  BEGIN
    DELETE FROM public.users WHERE id = OLD.id;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'Error in handle_auth_user_deleted for id=%: %', OLD.id, SQLERRM;
  END;
  RETURN OLD;
END;$$;
ALTER FUNCTION "public"."handle_auth_user_deleted"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  display_name_value text;
  account_type_value text;
BEGIN
  -- Get values from metadata if they exist
  display_name_value := NEW.raw_user_meta_data->>'display_name';
  account_type_value := NEW.raw_user_meta_data->>'role';

  -- Add error handling
  BEGIN
    IF display_name_value IS NOT NULL AND account_type_value IS NOT NULL AND account_type_value != '' THEN
      INSERT INTO public.users (id, email, display_name, account_type)
      VALUES (NEW.id, NEW.email, display_name_value, account_type_value::public.account_type);
    ELSIF display_name_value IS NOT NULL THEN
      INSERT INTO public.users (id, email, display_name)
      VALUES (NEW.id, NEW.email, display_name_value);
    ELSIF account_type_value IS NOT NULL AND account_type_value != '' THEN
      INSERT INTO public.users (id, email, account_type)
      VALUES (NEW.id, NEW.email, account_type_value::public.account_type);
    ELSE
      INSERT INTO public.users (id, email)
      VALUES (NEW.id, NEW.email);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Log the error
    RAISE LOG 'Error in handle_new_user: %', SQLERRM;
    -- Re-raise the error
    RAISE;
  END;
  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."handle_public_user_deleted"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  BEGIN
    DELETE FROM auth.users WHERE id = OLD.id;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'Error in handle_public_user_deleted: %', SQLERRM;
    RAISE;
  END;
  RETURN OLD;
END;
$$;
ALTER FUNCTION "public"."handle_public_user_deleted"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."process_family_center_insert"("p_record" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_catalan_data JSONB;
    v_webhook_result JSONB;
BEGIN
    -- Map to Catalan fields
    v_catalan_data := jsonb_build_object(
        'IdSupabase', p_record->>'id',
        'AutoIdFamiliaCentre', p_record->>'AutoIdFamiliaCentre',
        'Nom', p_record->>'name',
        'AutoIdMestreDelegacio', p_record->>'autoid_masterdelegation',
        'AutoIdMestreGrup', p_record->>'destination_id',
        'AutoIdProveidor', p_record->>'autoid_provider',
        'AutoIdFamiliaCoordinadora', p_record->>'autoid_coordinatingfamily',
        'NomIntern', p_record->>'internal_name',
        'NumLinies', p_record->>'number_of_lines',
        'Exclusivitat', CASE WHEN (p_record->>'exclusivity')::boolean THEN 1 ELSE 0 END,
        'FamiliesSimplificades', CASE WHEN (p_record->>'simplified_families')::boolean THEN 1 ELSE 0 END,
        'Actiu', CASE WHEN (p_record->>'active')::boolean THEN 1 ELSE 0 END,
        'AutoIdWebUsuariAlta', p_record->>'autoid_webuser_creation',
        'DataAlta', p_record->>'created_at'
    );
    
    -- Call external webhook
    v_webhook_result := call_external_webhook('INSERT', v_catalan_data);
    
    -- Return combined result
    RETURN jsonb_build_object(
        'operation', 'INSERT',
        'catalan_data', v_catalan_data,
        'webhook_result', v_webhook_result,
        'processed_at', NOW()
    );
END;
$$;
ALTER FUNCTION "public"."process_family_center_insert"("p_record" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."update_coordinator_uid"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$declare
  update_count integer := 0;
begin
  -- Only process if the inserted user is a coordinator
  if NEW.account_type = 'coordinator' then
    begin
      -- Update the coordinators table with the user's UUID
      update public.coordinators 
      set coodinator_uid = NEW.id
      where lower(coordinators.email) = lower(NEW.email);
      
    exception
      when others then
        -- Log the error but don't prevent the user insert
        raise notice 'Error updating coordinator_uid for user %: %', NEW.id, SQLERRM;
        -- Continue without failing the user insert
    end;
  end if;
  
  return NEW;
end;$$;
ALTER FUNCTION "public"."update_coordinator_uid"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."update_host_family_distances"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_host_lat double precision;
    v_host_lng double precision;
    v_nearest_meeting_point RECORD;
    v_distance_km double precision;
    v_distance_on_foot double precision; -- in kilometers
    v_distance_by_car double precision; -- in kilometers
BEGIN
    -- Only proceed if family_center_id has changed or is being set
    IF (TG_OP = 'INSERT' AND NEW.family_center_id IS NOT NULL) OR
       (TG_OP = 'UPDATE' AND (OLD.family_center_id IS DISTINCT FROM NEW.family_center_id)) THEN
        
        -- Get host family coordinates
        SELECT lat, lng 
        INTO v_host_lat, v_host_lng
        FROM public.host_family
        WHERE id = NEW.id;
        
        -- Check if coordinates exist
        IF v_host_lat IS NULL OR v_host_lng IS NULL THEN
            RAISE NOTICE 'Host family % does not have valid coordinates', NEW.id;
            RETURN NEW;
        END IF;
        
        -- Find the nearest meeting point for the family center
        SELECT 
            mp.id,
            mp.lat,
            mp.lng,
            calculate_haversine_distance(v_host_lat, v_host_lng, mp.lat, mp.lng) as distance
        INTO v_nearest_meeting_point
        FROM public.meeting_points mp
        WHERE mp.autoid_familycenter = NEW.family_center_id
            AND mp.lat IS NOT NULL
            AND mp.lng IS NOT NULL
        ORDER BY calculate_haversine_distance(v_host_lat, v_host_lng, mp.lat, mp.lng) ASC
        LIMIT 1;
        
        -- If a meeting point was found, store the distance in kilometers
        IF v_nearest_meeting_point.id IS NOT NULL THEN
            v_distance_km := v_nearest_meeting_point.distance;
            
            -- Store distance in kilometers (rounded to 2 decimal places)
            v_distance_on_foot := ROUND(v_distance_km::numeric, 2);
            v_distance_by_car := ROUND(v_distance_km::numeric, 2);
            
            -- Update the host family record
            NEW.distance_on_foot := v_distance_on_foot;
            NEW.distance_by_car := v_distance_by_car;
            
            RAISE NOTICE 'Updated distances for host family %: distance = % km', 
                NEW.id, v_distance_km;
        ELSE
            -- No meeting points found for this family center
            NEW.distance_on_foot := NULL;
            NEW.distance_by_car := NULL;
            
            RAISE NOTICE 'No meeting points found for family center %', NEW.family_center_id;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."update_host_family_distances"() OWNER TO "postgres";
SET default_tablespace = '';
SET default_table_access_method = "heap";
CREATE TABLE IF NOT EXISTS "public"."coordinators" (
    "id" bigint NOT NULL,
    "autoId_master_delegation" bigint,
    "name" "text",
    "nif_id" "text",
    "autoid_master_street_type" bigint,
    "street_name" "text",
    "street_number" "text",
    "staircase" character varying,
    "floor" character varying,
    "door" character varying,
    "postal_code" character varying,
    "town" character varying,
    "county_id" bigint,
    "province_id" bigint,
    "country_id" bigint,
    "phone" character varying,
    "mobile" character varying,
    "email" character varying,
    "notes" character varying,
    "autoid_webuser_created" bigint,
    "date_created" "date",
    "date_modified" "date",
    "autoid_webuser_deleted" bigint,
    "date_deleted" "date",
    "active" smallint,
    "autoid_webuser_modified" bigint,
    "coodinator_uid" "uuid",
    "autoId_familia_coordinator" bigint,
    "account_verification_status" "public"."verification_status",
    "address" "text",
    "country_code" "text"
);
ALTER TABLE "public"."coordinators" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "display_name" "text",
    "email" "text",
    "phone_number" "text",
    "is_profile_completed" boolean DEFAULT false,
    "date_of_birth" "date",
    "profile_picture" "text",
    "account_verified" boolean,
    "account_type" "public"."account_type",
    "account_verification_status" "public"."verification_status" DEFAULT 'pending'::"public"."verification_status",
    "account_rejection_message" "text",
    "coordinator_id" "uuid",
    "account_manager_id" "uuid",
    "customer_type" "public"."customer_type",
    "customer_connected_with_group" bigint,
    "select_language" "text",
    "auto_id_master_type" bigint,
    "auto_id_web_user_registration" bigint,
    "active" boolean,
    "user_tokens" "text",
    "sub_customer" "uuid"[],
    "family_center_id" bigint
);
ALTER TABLE ONLY "public"."users" REPLICA IDENTITY FULL;
ALTER TABLE "public"."users" OWNER TO "postgres";
COMMENT ON COLUMN "public"."users"."is_profile_completed" IS 'This variable is used for setting profile steps if it''s completed or not.';
COMMENT ON COLUMN "public"."users"."account_manager_id" IS 'Used it for customer type user only';
CREATE OR REPLACE VIEW "public"."admin_details" AS
 SELECT "u"."id" AS "user_id",
    "u"."created_at" AS "user_created_at",
        CASE
            WHEN (("u"."display_name" IS NOT NULL) AND ("u"."display_name" <> ''::"text")) THEN "u"."display_name"
            WHEN (("c"."name" IS NOT NULL) AND ("c"."name" <> ''::"text")) THEN "c"."name"
            ELSE NULL::"text"
        END AS "display_name",
        CASE
            WHEN (("u"."email" IS NOT NULL) AND ("u"."email" <> ''::"text")) THEN "u"."email"
            WHEN (("c"."email" IS NOT NULL) AND (("c"."email")::"text" <> ''::"text")) THEN ("c"."email")::"text"
            ELSE NULL::"text"
        END AS "email",
        CASE
            WHEN (("u"."phone_number" IS NOT NULL) AND ("u"."phone_number" <> ''::"text")) THEN "u"."phone_number"
            WHEN (("c"."phone" IS NOT NULL) AND (("c"."phone")::"text" <> ''::"text")) THEN ("c"."phone")::"text"
            WHEN (("c"."mobile" IS NOT NULL) AND (("c"."mobile")::"text" <> ''::"text")) THEN ("c"."mobile")::"text"
            ELSE NULL::"text"
        END AS "phone_number",
    "u"."profile_picture",
    "u"."date_of_birth",
    "u"."account_verified",
    "u"."account_type",
    COALESCE("u"."account_verification_status", "c"."account_verification_status") AS "account_verification_status",
    "u"."account_rejection_message",
    "c"."id" AS "coordinator_id",
    "c"."autoId_master_delegation",
    "c"."nif_id",
    "c"."autoid_master_street_type",
    "c"."street_name",
    "c"."street_number",
    "c"."staircase",
    "c"."floor",
    "c"."door",
    "c"."postal_code",
    "c"."town",
    "c"."county_id",
    "c"."province_id",
    "c"."country_id",
    "c"."mobile",
    "c"."notes",
    "c"."autoid_webuser_created",
    "c"."date_created" AS "coordinator_date_created",
    "c"."date_modified" AS "coordinator_date_modified",
    "c"."autoid_webuser_deleted",
    "c"."date_deleted",
    "c"."active",
    "c"."autoid_webuser_modified",
    "c"."coodinator_uid",
    "c"."autoId_familia_coordinator",
    "c"."address"
   FROM ("public"."users" "u"
     LEFT JOIN "public"."coordinators" "c" ON ((("u"."id" = "c"."coodinator_uid") OR ("u"."email" = ("c"."email")::"text") OR ("u"."phone_number" = ("c"."phone")::"text") OR ("u"."phone_number" = ("c"."mobile")::"text"))))
  WHERE ("u"."account_type" = ANY (ARRAY['admin'::"public"."account_type", 'super_admin'::"public"."account_type", 'coordinator'::"public"."account_type"]));
ALTER TABLE "public"."admin_details" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."assigned_role" (
    "id" bigint NOT NULL,
    "user" "text",
    "description" "text"
);
ALTER TABLE "public"."assigned_role" OWNER TO "postgres";
ALTER TABLE "public"."assigned_role" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."assigned_role_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."bookings" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone,
    "room_id" bigint,
    "check_in_date" timestamp with time zone,
    "check_out_date" timestamp with time zone,
    "host_family_status" "public"."booking_status" DEFAULT 'pending'::"public"."booking_status",
    "total_price" "text",
    "allergies" "text",
    "comments" "text",
    "assigned_at" timestamp with time zone DEFAULT "now"(),
    "assigned_by" "uuid",
    "assigned_host" bigint,
    "host_details" "json"[],
    "assigned_host_type" "public"."host_preference",
    "family_centers_id" bigint,
    "id" bigint NOT NULL,
    "host_family_id" bigint,
    "auto_id_group" bigint,
    "host_gender_master_id" bigint,
    "group_id" bigint,
    "extra_picnic" "text",
    "schedule_time" "json"[]
);
ALTER TABLE ONLY "public"."bookings" REPLICA IDENTITY FULL;
ALTER TABLE "public"."bookings" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."customer" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "autoid_customer" bigint,
    "autoid_fiscal_customer" bigint,
    "autoid_delegation_master" bigint,
    "autoid_customer_type_master" bigint,
    "autoid_accounting_code_master" bigint,
    "autoid_assigned_web_user" bigint,
    "autoid_category_master" bigint,
    "autoid_status_master" bigint,
    "autoid_study_plan_master" bigint,
    "autoid_bank_master" bigint,
    "customer_number" bigint,
    "first_name" "text",
    "last_name1" "text",
    "last_name2" "text",
    "company_name" "text",
    "accounting_code" "text",
    "nif_cif_valid" smallint,
    "nif_cif" "text",
    "autoid_street_type_master" bigint,
    "street_name" "text",
    "street_number" "text",
    "staircase" "text",
    "floor" "text",
    "door" "text",
    "postal_code" "text",
    "city" "text",
    "comarca_id" bigint,
    "province_id" bigint,
    "country_id" bigint,
    "phone" "text",
    "phone2" "text",
    "emergency_phone" "text",
    "mobile" "text",
    "mobile2" "text",
    "fax" "text",
    "email" "text",
    "additional_emails" "text",
    "password" "text",
    "facebook" "text",
    "website" "text",
    "twitter" "text",
    "notes" "text",
    "special_features" "text",
    "show_popup_message" smallint,
    "popup_message" "text",
    "autoid_created_web_user" bigint,
    "autoid_modified_web_user" bigint,
    "modified_at" "date",
    "autoid_deleted_web_user" bigint,
    "deleted_at" "date",
    "active" smallint,
    "autoid_transfer_web_user" bigint,
    "transfer_date" "date",
    "transferred" smallint,
    "customer_uid" "text",
    "account_verification_status" "text",
    "account_manager_id" "uuid",
    "address" "text",
    "country_code" "text"
);
ALTER TABLE "public"."customer" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."family_centers" (
    "name" "text",
    "id" bigint NOT NULL,
    "autoid_masterdelegation" bigint,
    "destination_id" bigint,
    "autoid_provider" bigint,
    "autoid_coordinatingfamily" bigint,
    "internal_name" "text",
    "description" "text",
    "number_of_lines" bigint,
    "exclusivity" boolean,
    "simplified_families" boolean,
    "active" boolean,
    "autoid_webuser_creation" integer,
    "autoid_webuser_modification" integer,
    "AutoIdFamiliaCentre" bigint,
    "created_at" timestamp without time zone
);
ALTER TABLE "public"."family_centers" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."groups" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "group_name" "text",
    "case_no" "text",
    "teacher_name" "text",
    "check_in_date" timestamp with time zone,
    "check_out_date" timestamp with time zone,
    "destinations" "json"[],
    "total_group" bigint,
    "no_of_girls" bigint,
    "no_of_boys" bigint,
    "no_of_teacher_women" bigint,
    "no_of_teacher_men" bigint,
    "schedule_time" "json"[],
    "adults" "text",
    "extra_picnic" "text",
    "emergency_phone" "text",
    "damage_insurance" "text",
    "liability_insurance" "text",
    "notes" "text",
    "teacher_hosting_preference" "text",
    "driver_hosting_preference" "text",
    "num_drivers" bigint,
    "tour_guide" "json"[],
    "need_tour_guide" "text",
    "status" "public"."group_status" DEFAULT 'pending'::"public"."group_status",
    "account_manager" "uuid",
    "customer_status" "public"."customer_status" DEFAULT 'option'::"public"."customer_status",
    "customer_assigned_at" timestamp with time zone,
    "additional_services" "text",
    "tour_guide_hosting_preference" "text",
    "client_expedient_id" bigint,
    "client_id" bigint,
    "delegation_id" smallint,
    "web_user_id" bigint,
    "season_id" smallint,
    "vat_regime_id" bigint,
    "expedient_type_id" bigint,
    "product_type_id" bigint,
    "expedient_status_id" bigint,
    "language_id" bigint,
    "client_contact_holder_rh_id" bigint,
    "Multiclient" smallint,
    "expedient_number" bigint,
    "client_name" "text",
    "route_name" "text",
    "num_students" smallint,
    "num_teachers" "text",
    "num_guides" smallint,
    "departure_date" "date",
    "arrival_date" "date",
    "expedient_opening" double precision,
    "total_budgeted" double precision,
    "total_collected" double precision,
    "total_paid" double precision,
    "total_invoiced" double precision,
    "total_supported" double precision,
    "total_irpf" double precision,
    "gross_margin" double precision,
    "margin_percentage" double precision,
    "observations" "text",
    "publish" smallint,
    "publish_start_date" "date",
    "publish_end_date" "date",
    "publish_doc_start_date" "date",
    "publish_doc_end_date" "date",
    "publish_payer" smallint,
    "publish_destination" smallint,
    "publish_doc_validity" smallint,
    "publish_doc_validity_months" smallint,
    "publish_passport_required" smallint,
    "publish_image_rights_module" smallint,
    "publish_extra_meal_price" double precision,
    "publish_registration_price" double precision,
    "publish_final_registration_price" smallint,
    "publish_show_registration_price" smallint,
    "publish_generic_docs" smallint,
    "publish_specific_docs" smallint,
    "publish_maps" smallint,
    "publish_insurances" smallint,
    "publish_vouchers" smallint,
    "publish_invoices" smallint,
    "publish_budget" smallint,
    "publish_precontract" smallint,
    "publish_contract" smallint,
    "publish_validated_data" "date",
    "publish_validated_data_date" timestamp with time zone,
    "modified_web_user_id" bigint,
    "modification_date" "date",
    "multi_client" smallint,
    "id" bigint NOT NULL,
    "customer_id" bigint,
    "option_id" bigint,
    "option_comments" "text"
);
ALTER TABLE "public"."groups" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."host_family" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "hostfamily_uid" "text",
    "display_name" "text",
    "email" "text",
    "phone_number" "text",
    "is_profile_completed" boolean,
    "current_profile_step" bigint,
    "dni_number" "text",
    "address" "text",
    "lat" double precision,
    "lng" double precision,
    "people_live_in_house" "text",
    "smokers" smallint,
    "languages_spoken" "text"[],
    "accepts_allergies" "text",
    "accepts_special_care" "text",
    "profile_picture" "text",
    "criminal_record" "text",
    "criminal_record_image" "text",
    "sexual_offenses" "text",
    "sexual_offenses_image" "text",
    "iban" "text",
    "account_verified" boolean,
    "blocked_dates" "jsonb"[],
    "account_verification_status" "public"."verification_status" DEFAULT 'pending'::"public"."verification_status",
    "account_rejection_message" "text",
    "has_children" boolean,
    "children_details" "text",
    "pets_details" "text",
    "last_check_in_date" timestamp with time zone,
    "select_language" "text",
    "autoid_family" bigint,
    "delegation_id" bigint,
    "wife_profession_id" bigint,
    "husband_profession_id" bigint,
    "wife_marital_status_id" bigint,
    "husband_marital_status_id" bigint,
    "coordinator_payment_method_id" bigint,
    "pipedrive_id" bigint,
    "wife_name" "text",
    "wife_birth_year" bigint,
    "wife_birth_date" "date",
    "wife_nif" "text",
    "wife_mobile" "text",
    "wife_phone" "text",
    "wife_email" "text",
    "whatsapp_verified" smallint,
    "has_vehicle" smallint,
    "husband_name" "text",
    "husband_birth_year" bigint,
    "husband_nif" "text",
    "husband_mobile" "text",
    "husband_phone" "text",
    "husband_email" "text",
    "street_type_id" bigint,
    "street_name" "text",
    "street_number" "text",
    "staircase" "text",
    "floor" "text",
    "door" "text",
    "postal_code" "text",
    "town" "text",
    "county_id" bigint,
    "province_id" bigint,
    "country_id" bigint,
    "has_people" smallint,
    "other_people" "text",
    "has_animals" smallint,
    "domestic_animals" "text",
    "french" smallint,
    "english" smallint,
    "disability" smallint,
    "background" smallint,
    "evaluation" "text",
    "bic" "text",
    "num_people" bigint,
    "pref_students" bigint,
    "pref_teachers" bigint,
    "pref_drivers" bigint,
    "pref_guides" bigint,
    "pref_boys" bigint,
    "pref_girls" bigint,
    "pref_indifferent" bigint,
    "accompany" smallint,
    "meals" smallint,
    "accommodation_desc_id" bigint,
    "accommodation_desc_text" "text",
    "num_single_rooms" bigint,
    "num_double_rooms" bigint,
    "double_rooms_text" "text",
    "num_triple_rooms" bigint,
    "triple_rooms_text" "text",
    "num_quadruple_rooms" bigint,
    "quadruple_rooms_text" "text",
    "num_bathrooms" bigint,
    "pool" smallint,
    "garden" smallint,
    "elevator" smallint,
    "adapted" smallint,
    "distance_on_foot" smallint,
    "distance_by_car" smallint,
    "rating" bigint,
    "photos" smallint,
    "notes" "text",
    "created_by_user_id" bigint,
    "modified_by_user_id" bigint,
    "modified_at" "date",
    "deleted_by_user_id" bigint,
    "deleted_at" "date",
    "exceptional" smallint,
    "simplified" smallint,
    "not_suitable" smallint,
    "active" smallint,
    "family_center_id" bigint,
    "coordinator_id" bigint,
    "guest_preferences" "text"[],
    "country_code" "text",
    "husband_birth_date" "date",
    "is_web" boolean DEFAULT true NOT NULL,
    "fcm_token" "text"
);
ALTER TABLE "public"."host_family" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."option" (
    "id" bigint NOT NULL,
    "autoid_client_option" bigint,
    "autoid_client" bigint,
    "autoid_client_contact" bigint,
    "autoid_client_expedient" bigint,
    "autoid_delegation_master" smallint,
    "autoid_season" smallint,
    "autoid_status_master" bigint,
    "autoid_product_type_master" bigint,
    "autoid_client_observations_master" bigint,
    "option_number" bigint,
    "option_date" timestamp with time zone,
    "deadline_date" "date",
    "meeting_date" "date",
    "group_name" "text",
    "school_name" "text",
    "teacher_name" "text",
    "town" "text",
    "num_students" smallint,
    "num_teachers" smallint,
    "num_drivers" smallint,
    "num_guides" smallint,
    "group_observations" "text",
    "internal_observations" "text",
    "travel_agency_observations" "text",
    "autoid_webuser_created" bigint,
    "created_date" timestamp with time zone,
    "autoid_webuser_modified" bigint,
    "modified_date" timestamp with time zone,
    "autoid_webuser_deleted" bigint,
    "deleted_date" timestamp with time zone,
    "case_no" "text",
    "total_group" bigint,
    "no_of_girls" smallint,
    "no_of_boys" smallint,
    "no_of_teacher_women" smallint,
    "no_of_teacher_men" smallint,
    "adults" "text",
    "extra_picnic" "text",
    "emergency_phone" "text",
    "damage_insurance" "text",
    "liability_insurance" "text",
    "teacher_hosting_preference" "text",
    "driver_hosting_preference" "text",
    "tour_guide" "jsonb"[],
    "status" "text",
    "account_manager" "uuid",
    "additional_services" "text",
    "tour_guide_hosting_preference" "text",
    "need_tour_guide" "text",
    "customer_status" "public"."customer_status" DEFAULT 'option'::"public"."customer_status",
    "schedule_time" "text"[],
    "destinations" "text"[],
    "country_code" "text",
    "expired_date" timestamp with time zone,
    "option_comments" "text"
);
ALTER TABLE "public"."option" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."booking_details" WITH ("security_invoker"='on') AS
 SELECT "b"."id" AS "booking_id",
    "b"."created_at" AS "booking_created_at",
    "b"."updated_at" AS "booking_updated_at",
    "b"."schedule_time",
    "b"."check_in_date",
    "b"."check_out_date",
    "b"."host_family_status" AS "booking_status",
    "b"."total_price",
    "b"."allergies",
    "b"."comments",
    "b"."extra_picnic",
    "b"."assigned_at",
    "b"."host_details",
    "b"."assigned_host",
    "b"."assigned_host_type",
    "b"."host_family_id",
    "b"."room_id",
    "b"."family_centers_id",
    "b"."group_id",
    "b"."assigned_by",
    "g"."group_name" AS "group_no",
    "o"."option_comments",
    ( SELECT "json_agg"("fc_element"."value") AS "json_agg"
           FROM "unnest"("o"."destinations") "dest"("dest"),
            LATERAL "jsonb_array_elements"((("dest"."dest")::"jsonb" -> 'family_center_value'::"text")) "fc_element"("value")
          WHERE (("dest"."dest")::"jsonb" ? 'family_center_value'::"text")) AS "meeting_points_data",
    "row_to_json"("hf".*) AS "host_family",
    "row_to_json"("g".*) AS "group_details",
    "row_to_json"("fc".*) AS "family_center",
        CASE
            WHEN (("b"."check_out_date" IS NOT NULL) AND ("b"."check_in_date" IS NOT NULL)) THEN EXTRACT(day FROM ("b"."check_out_date" - "b"."check_in_date"))
            ELSE NULL::numeric
        END AS "booking_duration_days"
   FROM (((((("public"."bookings" "b"
     LEFT JOIN "public"."host_family" "hf" ON (("b"."host_family_id" = "hf"."id")))
     LEFT JOIN "public"."coordinators" "coord" ON (("hf"."coordinator_id" = "coord"."autoId_familia_coordinator")))
     LEFT JOIN "public"."family_centers" "fc" ON (("b"."family_centers_id" = "fc"."AutoIdFamiliaCentre")))
     LEFT JOIN "public"."groups" "g" ON (("b"."group_id" = "g"."id")))
     LEFT JOIN "public"."option" "o" ON (("b"."group_id" = "o"."id")))
     LEFT JOIN "public"."customer" "gc" ON (("g"."customer_id" = "gc"."autoid_customer")))
  ORDER BY "b"."created_at" DESC;
ALTER TABLE "public"."booking_details" OWNER TO "postgres";
ALTER TABLE "public"."bookings" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."bookings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."client_expedient_option_family_center_family_stays" (
    "id" bigint NOT NULL,
    "client_expedient_option_family_center_family_stay_id" bigint,
    "client_expedient_option_family_center_family_id" bigint,
    "master_gender_id" bigint,
    "master_person_type_id" bigint,
    "start_date" "date",
    "end_date" "date",
    "num_participants" smallint,
    "observations" "text"
);
ALTER TABLE "public"."client_expedient_option_family_center_family_stays" OWNER TO "postgres";
ALTER TABLE "public"."client_expedient_option_family_center_family_stays" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."client_expedient_option_family_center_family_stays_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."client_option_family_centers" (
    "id" bigint NOT NULL,
    "client_option_family_center_id" bigint,
    "client_option_id" bigint,
    "family_center_option1_id" bigint,
    "family_center_option2_id" bigint,
    "client_expedient_full_control_id" bigint,
    "arrival_date" "date",
    "departure_date" "date",
    "num_students" smallint,
    "num_teachers" smallint,
    "num_drivers" smallint,
    "num_guides" smallint,
    "show_center" smallint,
    "show_rate" smallint,
    "observations" "text",
    "rate_observations" "text"
);
ALTER TABLE "public"."client_option_family_centers" OWNER TO "postgres";
ALTER TABLE "public"."client_option_family_centers" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."client_option_family_centers_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE OR REPLACE VIEW "public"."comprehensive_family_details" AS
SELECT
    NULL::bigint AS "family_id",
    NULL::timestamp with time zone AS "user_created_at",
    NULL::"text" AS "display_name",
    NULL::"text" AS "email",
    NULL::"text" AS "phone_number",
    NULL::"text" AS "profile_picture",
    NULL::boolean AS "is_profile_completed",
    NULL::bigint AS "current_profile_step",
    NULL::"date" AS "date_of_birth",
    NULL::"text" AS "dni_number",
    NULL::"text" AS "address",
    NULL::double precision AS "lat",
    NULL::double precision AS "lng",
    NULL::"text" AS "people_live_in_house",
    NULL::smallint AS "smokers",
    NULL::"text"[] AS "languages_spoken",
    NULL::smallint AS "disabilities_or_illnesses",
    NULL::"text" AS "accepts_allergies",
    NULL::"text" AS "accepts_special_care",
    NULL::smallint AS "accompany_the_student",
    NULL::smallint AS "has_a_car",
    NULL::"text" AS "criminal_record",
    NULL::"text" AS "criminal_record_image",
    NULL::"text" AS "sexual_offenses",
    NULL::"text" AS "sexual_offenses_image",
    NULL::"text" AS "iban",
    NULL::smallint AS "active",
    NULL::boolean AS "account_verified",
    NULL::"jsonb"[] AS "blocked_dates",
    NULL::"public"."verification_status" AS "account_verification_status",
    NULL::"text" AS "account_rejection_message",
    NULL::bigint AS "coordinator_id",
    NULL::bigint AS "family_center_id",
    NULL::timestamp with time zone AS "last_check_in_date",
    NULL::"text" AS "coordinator_name",
    NULL::"text" AS "family_center_name",
    NULL::boolean AS "has_children",
    NULL::"text" AS "children_details",
    NULL::smallint AS "has_pets",
    NULL::"text" AS "pets_details",
    NULL::"text"[] AS "guest_preferences",
    NULL::"text"[] AS "host_preference",
    NULL::bigint AS "autoid_family",
    NULL::bigint AS "wife_profession_id",
    NULL::bigint AS "wife_marital_status_id",
    NULL::bigint AS "wife_birth_year",
    NULL::"text" AS "wife_mobile",
    NULL::smallint AS "has_vehicle",
    NULL::"text" AS "husband_name",
    NULL::bigint AS "husband_profession_id",
    NULL::bigint AS "husband_birth_year",
    NULL::"text" AS "husband_mobile",
    NULL::"text" AS "husband_email",
    NULL::bigint AS "street_type_id",
    NULL::"text" AS "street_name",
    NULL::"text" AS "street_number",
    NULL::"text" AS "staircase",
    NULL::"text" AS "floor",
    NULL::"text" AS "door",
    NULL::"text" AS "postal_code",
    NULL::"text" AS "town",
    NULL::bigint AS "county_id",
    NULL::bigint AS "province_id",
    NULL::bigint AS "country_id",
    NULL::smallint AS "has_people",
    NULL::"text" AS "other_people",
    NULL::smallint AS "has_animals",
    NULL::"text" AS "domestic_animals",
    NULL::smallint AS "disability",
    NULL::smallint AS "background",
    NULL::"text" AS "evaluation",
    NULL::"text" AS "bic",
    NULL::bigint AS "num_people",
    NULL::smallint AS "accompany",
    NULL::"text" AS "accommodation_desc_text",
    NULL::smallint AS "distance_on_foot",
    NULL::smallint AS "distance_by_car",
    NULL::"text" AS "notes",
    NULL::"text" AS "country_code",
    NULL::"text" AS "hostfamily_uid",
    NULL::"date" AS "husband_birth_date",
    NULL::"text" AS "marital_status_code",
    NULL::"text" AS "address_edit_status",
    NULL::"text" AS "address_edit_new_value",
    NULL::"text" AS "hosting_capacity_edit_status",
    NULL::"text" AS "hosting_capacity_edit_new_value",
    NULL::bigint AS "partner_id",
    NULL::"text" AS "partner_name",
    NULL::"date" AS "partner_date_of_birth",
    NULL::"text" AS "partner_national_id",
    NULL::"text" AS "partner_phone_number",
    NULL::"text" AS "partner_email",
    NULL::bigint AS "house_id",
    NULL::timestamp with time zone AS "house_created_at",
    NULL::"text" AS "residence_type",
    NULL::"text" AS "elevator",
    NULL::"text" AS "hosting_capacity",
    NULL::"json"[] AS "rooms",
    NULL::"text" AS "bathroom_image",
    NULL::"text" AS "livingroom_image",
    NULL::"text" AS "kitchen_image",
    NULL::"text"[] AS "other_amenities",
    NULL::"text"[] AS "bathroom_images",
    NULL::"text"[] AS "livingroom_images",
    NULL::"text"[] AS "kitchen_images",
    NULL::"text"[] AS "other_area_images",
    NULL::numeric AS "distance_to_nearest_meeting_point_km",
    NULL::"jsonb" AS "nearest_meeting_point",
    NULL::"json"[] AS "my_bookings";
ALTER TABLE "public"."comprehensive_family_details" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."contact_us" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying(255) NOT NULL,
    "email" character varying(255) NOT NULL,
    "phone_number" character varying(20),
    "subject" character varying(255),
    "message" "text" NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"(),
    "status" character varying(50) DEFAULT 'new'::character varying,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);
ALTER TABLE "public"."contact_us" OWNER TO "postgres";
ALTER TABLE "public"."coordinators" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."coodinators_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."master" (
    "id" bigint NOT NULL,
    "autoid_master" bigint NOT NULL,
    "autoid_master_type" smallint,
    "autoid_mestre_delegation" smallint,
    "code" "text",
    "description" "text",
    "active" boolean
);
ALTER TABLE "public"."master" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."coordinator_details" WITH ("security_invoker"='on') AS
 SELECT "c"."autoId_familia_coordinator" AS "user_id",
    "c"."date_created" AS "user_created_at",
    "c"."name" AS "display_name",
    "c"."country_code",
    "c"."email",
    "c"."mobile" AS "phonenumber",
    "c"."account_verification_status",
    "c"."coodinator_uid",
    "c"."nif_id",
    "c"."autoid_master_street_type",
    "mt"."description" AS "street_type_description",
    "mt"."code",
    "c"."street_name",
    "c"."street_number",
    "c"."staircase",
    "c"."floor",
    "c"."door",
    "c"."postal_code",
    "c"."town",
    "c"."county_id",
    "c"."province_id",
    "c"."country_id",
    "c"."notes",
    "c"."address",
    "c"."active",
    ( SELECT "count"(*) AS "count"
           FROM "public"."family_centers" "fc"
          WHERE ("c"."autoId_familia_coordinator" = "fc"."autoid_coordinatingfamily")) AS "connected_family_center_count"
   FROM ("public"."coordinators" "c"
     LEFT JOIN "public"."master" "mt" ON (("c"."autoid_master_street_type" = "mt"."autoid_master")))
  WHERE ("c"."active" = 1);
ALTER TABLE "public"."coordinator_details" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."customer_details" WITH ("security_invoker"='on') AS
 SELECT "c"."autoid_customer" AS "user_id",
    "c"."created_at" AS "user_created_at",
    "c"."first_name" AS "display_name",
    "c"."email",
    "c"."country_code",
    "c"."customer_uid",
    "c"."phone" AS "phone_number",
    "c"."account_verification_status",
    "c"."autoid_accounting_code_master",
    "c"."autoid_assigned_web_user",
    "c"."autoid_category_master",
    "c"."autoid_status_master",
    "c"."customer_number",
    "c"."company_name",
    "c"."accounting_code",
    "c"."autoid_street_type_master",
    "c"."street_name",
    "c"."street_number",
    "c"."staircase",
    "c"."address",
    "c"."floor",
    "c"."door",
    "c"."active",
    "c"."account_manager_id",
    "c"."postal_code",
    "c"."city",
    "c"."comarca_id",
    "c"."province_id",
    "c"."country_id",
    "c"."nif_cif",
    "c"."autoid_customer_type_master",
    "am"."display_name" AS "account_manager_name",
    "m"."description" AS "customer_type",
    "count"("g"."id") AS "customer_connected_with_group"
   FROM ((("public"."customer" "c"
     LEFT JOIN "public"."users" "am" ON (("c"."account_manager_id" = "am"."id")))
     LEFT JOIN "public"."master" "m" ON (("c"."autoid_customer_type_master" = "m"."autoid_master")))
     LEFT JOIN "public"."groups" "g" ON (("c"."autoid_customer" = "g"."customer_id")))
  GROUP BY "c"."autoid_customer", "c"."created_at", "c"."first_name", "c"."email", "c"."phone", "c"."account_verification_status", "c"."autoid_accounting_code_master", "c"."autoid_assigned_web_user", "c"."autoid_category_master", "c"."autoid_status_master", "c"."customer_number", "c"."company_name", "c"."customer_uid", "c"."accounting_code", "c"."autoid_street_type_master", "c"."street_name", "c"."street_number", "c"."staircase", "c"."country_code", "c"."address", "c"."floor", "c"."door", "c"."active", "c"."account_manager_id", "c"."postal_code", "c"."city", "c"."comarca_id", "c"."province_id", "c"."country_id", "c"."nif_cif", "c"."autoid_customer_type_master", "am"."display_name", "m"."description";
ALTER TABLE "public"."customer_details" OWNER TO "postgres";
ALTER TABLE "public"."customer" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."customer_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."destinations" (
    "autoid_master" bigint NOT NULL,
    "autoid_master_type" smallint,
    "autoid_mestre_delegation" smallint,
    "code" "text",
    "description" "text",
    "active" smallint,
    "id" bigint NOT NULL
);
ALTER TABLE "public"."destinations" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."destination_details" AS
 SELECT "d"."autoid_master",
    "d"."code",
    "count"("fc"."id") AS "usage_count"
   FROM ("public"."destinations" "d"
     LEFT JOIN "public"."family_centers" "fc" ON (("d"."autoid_master" = "fc"."destination_id")))
  GROUP BY "d"."autoid_master", "d"."code";
ALTER TABLE "public"."destination_details" OWNER TO "postgres";
ALTER TABLE "public"."destinations" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."destinations_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."meeting_points" (
    "name" "text",
    "address" "text",
    "lat" double precision,
    "lng" double precision,
    "type" "public"."meeting_point_type" DEFAULT 'meeting_point'::"public"."meeting_point_type",
    "id" bigint NOT NULL,
    "autoid_familycenter" bigint,
    "autoid_season" bigint,
    "morning_schedule_start" time without time zone,
    "morning_schedule_end" time without time zone,
    "afternoon_schedule_start" time without time zone,
    "afternoon_schedule_end" time without time zone,
    "autoid_meetingpoint" bigint
);
ALTER TABLE "public"."meeting_points" OWNER TO "postgres";
COMMENT ON COLUMN "public"."meeting_points"."lat" IS 'Used to store latitude of meeting point.';
COMMENT ON COLUMN "public"."meeting_points"."lng" IS 'Used to store longitude of meeting point';
CREATE TABLE IF NOT EXISTS "public"."room_records" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "residence_type" "text",
    "elevator" "text",
    "hosting_capacity" "text",
    "rooms" "json"[],
    "bathroom_image" "text",
    "livingroom_image" "text",
    "kitchen_image" "text",
    "other_amenities" "text"[],
    "bathroom_images" "text"[],
    "livingroom_images" "text"[],
    "kitchen_images" "text"[],
    "other_area_images" "text"[],
    "host_preference" "public"."host_preference"[],
    "family_id" bigint,
    "hostfamily_uid" "uuid"
);
ALTER TABLE "public"."room_records" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."family_centers_details" WITH ("security_invoker"='on') AS
 SELECT "fc"."AutoIdFamiliaCentre" AS "id",
    "fc"."created_at",
    "fc"."name",
    "fc"."autoid_coordinatingfamily",
    "fc"."active",
    "fc"."AutoIdFamiliaCentre" AS "autoid_familia_centre",
    ( SELECT "json_agg"("cd".*) AS "json_agg"
           FROM "public"."coordinators" "cd"
          WHERE ("cd"."autoId_familia_coordinator" = "fc"."autoid_coordinatingfamily")) AS "coordinator_details",
    "fc"."destination_id",
    COALESCE(( SELECT "to_json"("dd".*) AS "to_json"
           FROM "public"."destination_details" "dd"
          WHERE ("dd"."autoid_master" = "fc"."destination_id")
         LIMIT 1)) AS "destination_details",
    ( SELECT COALESCE("json_agg"("mp".*), '[]'::"json") AS "coalesce"
           FROM "public"."meeting_points" "mp"
          WHERE ("mp"."autoid_familycenter" = "fc"."AutoIdFamiliaCentre")) AS "meeting_points",
    ( SELECT "count"(*) AS "count"
           FROM "public"."host_family" "h"
          WHERE ("h"."family_center_id" = "fc"."AutoIdFamiliaCentre")) AS "number_of_families",
    COALESCE(( SELECT "json_agg"("json_build_object"('id', "f"."autoid_family", 'display_name', "f"."display_name")) AS "json_agg"
           FROM "public"."host_family" "f"
          WHERE ("f"."family_center_id" = "fc"."AutoIdFamiliaCentre")), '[]'::"json") AS "family_details",
    (0)::bigint AS "no_of_girls",
    (0)::bigint AS "no_of_boys",
    (0)::bigint AS "no_of_teacher_women",
    (0)::bigint AS "no_of_teacher_men",
    (0)::bigint AS "no_of_driver",
    (0)::bigint AS "no_of_tour_guide",
    COALESCE(( SELECT "sum"(
                CASE
                    WHEN (("rr"."rooms" IS NOT NULL) AND ("array_length"("rr"."rooms", 1) > 0)) THEN ( SELECT "sum"((("room_elem"."value" ->> 'bedroom_type'::"text"))::integer) AS "sum"
                       FROM "jsonb_array_elements"(((('['::"text" || "array_to_string"("rr"."rooms", ','::"text")) || ']'::"text"))::"jsonb") "room_elem"("value")
                      WHERE ("room_elem"."value" ? 'bedroom_type'::"text"))
                    WHEN (("rr"."hosting_capacity" IS NOT NULL) AND ("rr"."hosting_capacity" ~ '^[0-9]+$'::"text")) THEN (("rr"."hosting_capacity")::integer)::bigint
                    ELSE (0)::bigint
                END) AS "sum"
           FROM ("public"."room_records" "rr"
             JOIN "public"."host_family" "h" ON (("rr"."family_id" = "h"."autoid_family")))
          WHERE ("h"."family_center_id" = "fc"."AutoIdFamiliaCentre")), (0)::numeric) AS "total_host_capacity"
   FROM "public"."family_centers" "fc";
ALTER TABLE "public"."family_centers_details" OWNER TO "postgres";
COMMENT ON VIEW "public"."family_centers_details" IS 'Detailed view of family centers including meeting points and associated family count';
ALTER TABLE "public"."family_centers" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."family_centers_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."feedback" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_name" "text",
    "average_review" double precision,
    "have_a_good_experience" "text",
    "house_as_described" "text",
    "cleanliness" double precision,
    "comfort" double precision,
    "host_friendliness" double precision,
    "amenities" double precision,
    "communication" double precision,
    "room_quality" double precision,
    "your_thoughts_about_house" "text",
    "feedback_status" "public"."feedback_status" DEFAULT 'pending'::"public"."feedback_status"
);
ALTER TABLE "public"."feedback" OWNER TO "postgres";
ALTER TABLE "public"."feedback" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."feedback_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE OR REPLACE VIEW "public"."groups_details" AS
SELECT
    NULL::bigint AS "id",
    NULL::timestamp with time zone AS "created_at",
    NULL::"text" AS "group_name",
    NULL::bigint AS "option_number",
    NULL::bigint AS "autoid_client_option",
    NULL::"text" AS "case_no",
    NULL::timestamp with time zone AS "expired_date",
    NULL::"text" AS "country_code",
    NULL::"text" AS "option_comments",
    NULL::bigint AS "customer_id",
    NULL::bigint AS "autoid_status_master",
    NULL::"text" AS "option_status",
    NULL::"text" AS "product_type_code",
    NULL::bigint AS "autoid_product_type_master",
    NULL::bigint AS "autoid_client_expedient",
    NULL::"text" AS "customer_email",
    NULL::"text" AS "account_manager_email",
    NULL::"text" AS "customer_name",
    NULL::"text" AS "teacher_name",
    NULL::"text" AS "school_name",
    NULL::"date" AS "check_in_date",
    NULL::"date" AS "check_out_date",
    NULL::"jsonb"[] AS "destinations",
    NULL::bigint AS "total_group",
    NULL::smallint AS "no_of_girls",
    NULL::smallint AS "no_of_boys",
    NULL::smallint AS "no_of_teacher_women",
    NULL::smallint AS "no_of_teacher_men",
    NULL::smallint AS "no_of_driver",
    NULL::"jsonb"[] AS "schedule_time",
    NULL::"text" AS "adults",
    NULL::"text" AS "extra_picnic",
    NULL::"text" AS "emergency_phone",
    NULL::"text" AS "damage_insurance",
    NULL::"text" AS "liability_insurance",
    NULL::"text" AS "notes",
    NULL::"text" AS "teacher_hosting_preference",
    NULL::"text" AS "driver_hosting_preference",
    NULL::"text" AS "tour_guide_hosting_preference",
    NULL::"public"."customer_status" AS "customer_status",
    NULL::"text" AS "status",
    NULL::"text" AS "need_tour_guide",
    NULL::"jsonb"[] AS "tour_guide",
    NULL::"uuid" AS "account_manager",
    NULL::"text" AS "account_manager_name",
    NULL::"text" AS "additional_services",
    NULL::boolean AS "convert_group",
    NULL::integer AS "total_host",
    NULL::numeric AS "assigned_girls",
    NULL::numeric AS "assigned_boys",
    NULL::numeric AS "assigned_teacher_women",
    NULL::numeric AS "assigned_teacher_men",
    NULL::numeric AS "assigned_driver",
    NULL::numeric AS "assigned_tour_guide",
    NULL::numeric AS "total_assigned_host",
    NULL::numeric AS "remaining_girls",
    NULL::numeric AS "remaining_boys",
    NULL::numeric AS "remaining_teacher_women",
    NULL::numeric AS "remaining_teacher_men",
    NULL::numeric AS "remaining_driver",
    NULL::numeric AS "remaining_tour_guide",
    NULL::numeric AS "total_remaining_host",
    NULL::"jsonb"[] AS "all_family_centers",
    NULL::"text"[] AS "coordinator_ids";
ALTER TABLE "public"."groups_details" OWNER TO "postgres";
ALTER TABLE "public"."groups" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."groups_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
ALTER TABLE "public"."host_family" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."host_family_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."master_comarca" (
    "comarca_id" bigint NOT NULL,
    "descripcio" "text"
);
ALTER TABLE "public"."master_comarca" OWNER TO "postgres";
COMMENT ON TABLE "public"."master_comarca" IS 'county';
ALTER TABLE "public"."master_comarca" ALTER COLUMN "comarca_id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."master_comarca_comarca_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."master_country" (
    "id_pais" bigint NOT NULL,
    "description" "text",
    "ISO3166-1-1" bigint,
    "ISO3166-1-2" "text",
    "ISO3166-1-3" "text"
);
ALTER TABLE "public"."master_country" OWNER TO "postgres";
ALTER TABLE "public"."master_country" ALTER COLUMN "id_pais" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."master_country_id_pais_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
ALTER TABLE "public"."master" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."master_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."master_postal_code" (
    "postal_code_id" bigint NOT NULL,
    "population_name" "text",
    "postal_code" "text",
    "locality" "text",
    "municipality_code_ine" "text",
    "county_id" bigint,
    "province_id" bigint,
    "country_id" bigint
);
ALTER TABLE "public"."master_postal_code" OWNER TO "postgres";
COMMENT ON COLUMN "public"."master_postal_code"."postal_code_id" IS 'CP';
COMMENT ON COLUMN "public"."master_postal_code"."population_name" IS 'CPPoblació';
COMMENT ON COLUMN "public"."master_postal_code"."locality" IS 'Localitat';
ALTER TABLE "public"."master_postal_code" ALTER COLUMN "postal_code_id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."master_postal_code_postal_code_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."master_province" (
    "province_id" bigint NOT NULL,
    "description" "text"
);
ALTER TABLE "public"."master_province" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."meeting_point_details" AS
 SELECT "mp"."autoid_meetingpoint" AS "id",
    "mp"."name",
    "mp"."address",
    "mp"."lat",
    "mp"."lng",
    "mp"."type",
    "mp"."autoid_familycenter",
    "mp"."morning_schedule_start",
    "mp"."morning_schedule_end",
    "mp"."afternoon_schedule_start",
    "mp"."afternoon_schedule_end",
    "fc"."active" AS "family_center_active",
    "fc"."AutoIdFamiliaCentre" AS "family_center_id",
    "fc"."name" AS "family_center_name",
    "fc"."autoid_coordinatingfamily",
    "count"("fc"."AutoIdFamiliaCentre") OVER (PARTITION BY "mp"."autoid_meetingpoint") AS "used_in_places_count",
    ("fc"."AutoIdFamiliaCentre" IS NOT NULL) AS "is_assigned"
   FROM ("public"."meeting_points" "mp"
     LEFT JOIN "public"."family_centers" "fc" ON (("mp"."autoid_familycenter" = "fc"."AutoIdFamiliaCentre")))
  WHERE ("fc"."active" = true);
ALTER TABLE "public"."meeting_point_details" OWNER TO "postgres";
ALTER TABLE "public"."meeting_points" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."meeting_points_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."notification" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "title" "text",
    "description" "text",
    "receiver" "text"[],
    "sender" "text"
);
ALTER TABLE "public"."notification" OWNER TO "postgres";
ALTER TABLE "public"."notification" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."notification_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE OR REPLACE VIEW "public"."option_details" AS
SELECT
    NULL::bigint AS "id",
    NULL::timestamp with time zone AS "created_at",
    NULL::"text" AS "group_name",
    NULL::bigint AS "option_number",
    NULL::"text" AS "case_no",
    NULL::bigint AS "customer_id",
    NULL::bigint AS "autoid_status_master",
    NULL::bigint AS "autoid_product_type_master",
    NULL::bigint AS "autoid_client_expedient",
    NULL::"text" AS "customer_email",
    NULL::"text" AS "account_manager_email",
    NULL::"text" AS "customer_name",
    NULL::"text" AS "teacher_name",
    NULL::"text" AS "school_name",
    NULL::"date" AS "check_in_date",
    NULL::"date" AS "check_out_date",
    NULL::"jsonb"[] AS "destinations",
    NULL::bigint AS "total_group",
    NULL::smallint AS "no_of_girls",
    NULL::smallint AS "no_of_boys",
    NULL::smallint AS "no_of_teacher_women",
    NULL::smallint AS "no_of_teacher_men",
    NULL::smallint AS "no_of_driver",
    NULL::"jsonb"[] AS "schedule_time",
    NULL::"text" AS "adults",
    NULL::"text" AS "extra_picnic",
    NULL::"text" AS "emergency_phone",
    NULL::"text" AS "damage_insurance",
    NULL::"text" AS "liability_insurance",
    NULL::"text" AS "notes",
    NULL::"text" AS "teacher_hosting_preference",
    NULL::"text" AS "driver_hosting_preference",
    NULL::"text" AS "tour_guide_hosting_preference",
    NULL::"public"."customer_status" AS "customer_status",
    NULL::"text" AS "status",
    NULL::"text" AS "need_tour_guide",
    NULL::"jsonb"[] AS "tour_guide",
    NULL::"uuid" AS "account_manager",
    NULL::"text" AS "account_manager_name",
    NULL::"text" AS "additional_services",
    NULL::integer AS "total_host",
    NULL::numeric AS "assigned_girls",
    NULL::numeric AS "assigned_boys",
    NULL::numeric AS "assigned_teacher_women",
    NULL::numeric AS "assigned_teacher_men",
    NULL::numeric AS "assigned_driver",
    NULL::numeric AS "assigned_tour_guide",
    NULL::numeric AS "total_assigned_host",
    NULL::numeric AS "remaining_girls",
    NULL::numeric AS "remaining_boys",
    NULL::numeric AS "remaining_teacher_women",
    NULL::numeric AS "remaining_teacher_men",
    NULL::numeric AS "remaining_driver",
    NULL::numeric AS "remaining_tour_guide",
    NULL::numeric AS "total_remaining_host",
    NULL::"jsonb"[] AS "all_family_centers",
    NULL::"text"[] AS "coordinator_ids";
ALTER TABLE "public"."option_details" OWNER TO "postgres";
ALTER TABLE "public"."option" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."option_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."partner_details" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"(),
    "name" "text",
    "date_of_birth" "date",
    "national_id" "text",
    "phone_number" "text",
    "email" "text"
);
ALTER TABLE "public"."partner_details" OWNER TO "postgres";
ALTER TABLE "public"."partner_details" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."partner_details_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE OR REPLACE VIEW "public"."postal_code_view" AS
 SELECT "pc"."postal_code_id",
    "pc"."population_name",
    "pc"."postal_code",
    "pc"."locality",
    "pc"."municipality_code_ine",
    "pc"."county_id",
    "c"."descripcio" AS "county_description",
    "pc"."province_id",
    "p"."description" AS "province_description",
    "pc"."country_id",
    "co"."description" AS "country_description",
    "co"."ISO3166-1-1" AS "iso3166_1_1",
    "co"."ISO3166-1-2" AS "iso3166_1_2",
    "co"."ISO3166-1-3" AS "iso3166_1_3"
   FROM ((("public"."master_postal_code" "pc"
     LEFT JOIN "public"."master_comarca" "c" ON (("pc"."county_id" = "c"."comarca_id")))
     LEFT JOIN "public"."master_province" "p" ON (("pc"."province_id" = "p"."province_id")))
     LEFT JOIN "public"."master_country" "co" ON (("pc"."country_id" = "co"."id_pais")));
ALTER TABLE "public"."postal_code_view" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."profile_edit_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "hostfamily_id" bigint,
    "field_name" "text" NOT NULL,
    "old_value" "text",
    "new_value" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "data" "json",
    "hostfamily_uid" "uuid",
    "hosting_capacity_new" "text",
    "room_record_new" "json"[],
    CONSTRAINT "profile_edit_requests_field_name_check" CHECK (("field_name" = ANY (ARRAY['address'::"text", 'num_bedrooms'::"text", 'hosting_capacity'::"text"]))),
    CONSTRAINT "profile_edit_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);
ALTER TABLE "public"."profile_edit_requests" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."profile_edit_requests_view" AS
 SELECT "per"."id",
    "per"."hostfamily_id",
    "per"."field_name",
    "per"."old_value",
    "per"."new_value",
    "per"."status",
    "per"."reason",
    "per"."created_at",
    "per"."updated_at",
    "per"."data",
    "per"."hostfamily_uid",
    "per"."hosting_capacity_new",
    "per"."room_record_new",
    "hf"."wife_name" AS "family_name",
    "hf"."email",
    "hf"."phone_number"
   FROM ("public"."profile_edit_requests" "per"
     LEFT JOIN "public"."host_family" "hf" ON (("per"."hostfamily_id" = "hf"."id")));
ALTER TABLE "public"."profile_edit_requests_view" OWNER TO "postgres";
ALTER TABLE "public"."master_province" ALTER COLUMN "province_id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."province_province_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."road_type" (
    "id" bigint NOT NULL,
    "autoid_master" bigint NOT NULL,
    "code" "text",
    "description" "text",
    "autoid_master_type" smallint,
    "autoid_mestre_delegation" smallint,
    "active" smallint
);
ALTER TABLE "public"."road_type" OWNER TO "postgres";
ALTER TABLE "public"."road_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."road_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
ALTER TABLE "public"."room_records" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."rooms_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE OR REPLACE VIEW "public"."user_details" AS
 SELECT "u"."id",
    "u"."email",
    "u"."phone_number" AS "phone",
    "u"."account_type"
   FROM ("public"."users" "u"
     JOIN "public"."coordinators" "c" ON (("u"."id" = "c"."coodinator_uid")))
  WHERE ("c"."active" = 1)
UNION ALL
 SELECT "u"."id",
    "u"."email",
    "u"."phone_number" AS "phone",
    "u"."account_type"
   FROM ("public"."users" "u"
     JOIN "public"."host_family" "h" ON ((("u"."id")::"text" = "h"."hostfamily_uid")))
  WHERE ("h"."active" = 1)
UNION ALL
 SELECT "u"."id",
    "u"."email",
    "u"."phone_number" AS "phone",
    "u"."account_type"
   FROM "public"."users" "u"
  WHERE ("u"."account_type" = ANY (ARRAY['super_admin'::"public"."account_type", 'admin'::"public"."account_type"]));
ALTER TABLE "public"."user_details" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."webhook_queue" (
    "id" bigint NOT NULL,
    "operation" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "target_url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "processed" boolean DEFAULT false,
    "attempts" integer DEFAULT 0,
    "last_attempt" timestamp with time zone,
    "error_message" "text"
);
ALTER TABLE "public"."webhook_queue" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."webhook_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER TABLE "public"."webhook_queue_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."webhook_queue_id_seq" OWNED BY "public"."webhook_queue"."id";
CREATE TABLE IF NOT EXISTS "public"."wife_marital_status" (
    "id" bigint NOT NULL,
    "autoid_master" bigint,
    "code" "text",
    "autoid_master_type" smallint,
    "autoid_mestre_delegation" smallint,
    "description" "text",
    "active" smallint
);
ALTER TABLE "public"."wife_marital_status" OWNER TO "postgres";
ALTER TABLE "public"."wife_marital_status" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."wife_marital_status_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
ALTER TABLE ONLY "public"."webhook_queue" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."webhook_queue_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."assigned_role"
    ADD CONSTRAINT "assigned_role_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."client_expedient_option_family_center_family_stays"
    ADD CONSTRAINT "client_expedient_option_family_center_family_stays_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."client_option_family_centers"
    ADD CONSTRAINT "client_option_family_centers_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."contact_us"
    ADD CONSTRAINT "contact_us_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."coordinators"
    ADD CONSTRAINT "coodinators_coodinator_uid_key" UNIQUE ("coodinator_uid");
ALTER TABLE ONLY "public"."coordinators"
    ADD CONSTRAINT "coodinators_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."coordinators"
    ADD CONSTRAINT "coodinators_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."customer"
    ADD CONSTRAINT "customer_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."destinations"
    ADD CONSTRAINT "destinations_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."destinations"
    ADD CONSTRAINT "destinations_pkey" PRIMARY KEY ("autoid_master");
ALTER TABLE ONLY "public"."family_centers"
    ADD CONSTRAINT "family_centers_AutoIdFamiliaCentre_key" UNIQUE ("AutoIdFamiliaCentre");
ALTER TABLE ONLY "public"."family_centers"
    ADD CONSTRAINT "family_centers_duplicate_autoid_familycenter_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."family_centers"
    ADD CONSTRAINT "family_centers_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."host_family"
    ADD CONSTRAINT "host_family_autoid_family_key" UNIQUE ("autoid_family");
ALTER TABLE ONLY "public"."host_family"
    ADD CONSTRAINT "host_family_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."master"
    ADD CONSTRAINT "master_autoid_master_key" UNIQUE ("autoid_master");
ALTER TABLE ONLY "public"."master_comarca"
    ADD CONSTRAINT "master_comarca_pkey" PRIMARY KEY ("comarca_id");
ALTER TABLE ONLY "public"."master_country"
    ADD CONSTRAINT "master_country_pkey" PRIMARY KEY ("id_pais");
ALTER TABLE ONLY "public"."master"
    ADD CONSTRAINT "master_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."master"
    ADD CONSTRAINT "master_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."master_postal_code"
    ADD CONSTRAINT "master_postal_code_pkey" PRIMARY KEY ("postal_code_id");
ALTER TABLE ONLY "public"."meeting_points"
    ADD CONSTRAINT "meeting_points_autoid_meetingpoint_key" UNIQUE ("autoid_meetingpoint");
ALTER TABLE ONLY "public"."meeting_points"
    ADD CONSTRAINT "meeting_points_duplicate_auto_id_meetingpoint_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."meeting_points"
    ADD CONSTRAINT "meeting_points_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."notification"
    ADD CONSTRAINT "notification_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."option"
    ADD CONSTRAINT "option_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."partner_details"
    ADD CONSTRAINT "partner_details_family_id_key" UNIQUE ("user_id");
ALTER TABLE ONLY "public"."partner_details"
    ADD CONSTRAINT "partner_details_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."profile_edit_requests"
    ADD CONSTRAINT "profile_edit_requests_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."master_province"
    ADD CONSTRAINT "province_pkey" PRIMARY KEY ("province_id");
ALTER TABLE ONLY "public"."road_type"
    ADD CONSTRAINT "road_type_autoId_master_key" UNIQUE ("autoid_master");
ALTER TABLE ONLY "public"."road_type"
    ADD CONSTRAINT "road_type_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."road_type"
    ADD CONSTRAINT "road_type_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."room_records"
    ADD CONSTRAINT "rooms_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_key" UNIQUE ("id");
ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_phone_number_key" UNIQUE ("phone_number");
ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."webhook_queue"
    ADD CONSTRAINT "webhook_queue_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."wife_marital_status"
    ADD CONSTRAINT "wife_marital_status_autoid_mestre_key" UNIQUE ("autoid_master");
ALTER TABLE ONLY "public"."wife_marital_status"
    ADD CONSTRAINT "wife_marital_status_pkey" PRIMARY KEY ("id");
CREATE INDEX "idx_bookings_check_in_date" ON "public"."bookings" USING "btree" ("check_in_date");
CREATE INDEX "idx_bookings_check_out_date" ON "public"."bookings" USING "btree" ("check_out_date");
CREATE INDEX "idx_bookings_status" ON "public"."bookings" USING "btree" ("host_family_status");
CREATE INDEX "idx_partner_details_user_id" ON "public"."partner_details" USING "btree" ("user_id");
CREATE INDEX "idx_users_account_type" ON "public"."users" USING "btree" ("account_type");
CREATE INDEX "idx_users_account_type_verified" ON "public"."users" USING "btree" ("account_type", "account_verified");
CREATE INDEX "idx_users_account_verification_status" ON "public"."users" USING "btree" ("account_verification_status");
CREATE INDEX "idx_users_account_verified" ON "public"."users" USING "btree" ("account_verified");
CREATE INDEX "idx_users_coordinator_id" ON "public"."users" USING "btree" ("coordinator_id");
CREATE INDEX "idx_users_is_profile_completed" ON "public"."users" USING "btree" ("is_profile_completed");
CREATE INDEX "idx_webhook_queue_processed" ON "public"."webhook_queue" USING "btree" ("processed", "created_at");
CREATE INDEX "users_account_type_id_idx" ON "public"."users" USING "btree" ("account_type", "id");
CREATE INDEX "users_created_at_id_display_name_idx" ON "public"."users" USING "btree" ("created_at", "id", "display_name");
CREATE OR REPLACE VIEW "public"."option_details" WITH ("security_invoker"='on') AS
 SELECT "o"."id",
    "o"."created_date" AS "created_at",
    "o"."group_name",
    "o"."option_number",
    "o"."case_no",
    "o"."autoid_client" AS "customer_id",
    "o"."autoid_status_master",
    "o"."autoid_product_type_master",
    "o"."autoid_client_expedient",
    "c"."email" AS "customer_email",
    "am"."email" AS "account_manager_email",
    "c"."first_name" AS "customer_name",
    "o"."teacher_name",
    "o"."school_name",
    "o"."meeting_date" AS "check_in_date",
    "o"."deadline_date" AS "check_out_date",
    ( SELECT
                CASE
                    WHEN ("count"("u"."dest_elem") = 0) THEN NULL::"jsonb"[]
                    ELSE "array_agg"(("u"."dest_elem")::"jsonb")
                END AS "array_agg"
           FROM "unnest"("o"."destinations") "u"("dest_elem")) AS "destinations",
    "o"."total_group",
    "o"."no_of_girls",
    "o"."no_of_boys",
    "o"."no_of_teacher_women",
    "o"."no_of_teacher_men",
    "o"."num_drivers" AS "no_of_driver",
    ( SELECT
                CASE
                    WHEN ("count"("st"."st_elem") = 0) THEN NULL::"jsonb"[]
                    ELSE "array_agg"(("st"."st_elem")::"jsonb")
                END AS "array_agg"
           FROM "unnest"("o"."schedule_time") "st"("st_elem")) AS "schedule_time",
    "o"."adults",
    "o"."extra_picnic",
    "o"."emergency_phone",
    "o"."damage_insurance",
    "o"."liability_insurance",
    "o"."group_observations" AS "notes",
    "o"."teacher_hosting_preference",
    "o"."driver_hosting_preference",
    "o"."tour_guide_hosting_preference",
    "o"."customer_status",
    COALESCE("status_analysis"."status", 'pending'::"text") AS "status",
    "o"."need_tour_guide",
    "o"."tour_guide",
    "o"."account_manager",
    "am"."display_name" AS "account_manager_name",
    "o"."additional_services",
    (((("o"."no_of_girls" + "o"."no_of_boys") +
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
        END) +
        CASE
            WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE(("o"."num_drivers")::integer, 0)
        END) +
        CASE
            WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
        END) AS "total_host",
    COALESCE("booking_stats"."assigned_girls", (0)::numeric) AS "assigned_girls",
    COALESCE("booking_stats"."assigned_boys", (0)::numeric) AS "assigned_boys",
    COALESCE("booking_stats"."assigned_teacher_women", (0)::numeric) AS "assigned_teacher_women",
    COALESCE("booking_stats"."assigned_teacher_men", (0)::numeric) AS "assigned_teacher_men",
    COALESCE("booking_stats"."assigned_driver", (0)::numeric) AS "assigned_driver",
    COALESCE("booking_stats"."assigned_tour_guide", (0)::numeric) AS "assigned_tour_guide",
    COALESCE("booking_stats"."total_assigned_host", (0)::numeric) AS "total_assigned_host",
    GREATEST(((COALESCE(("o"."no_of_girls")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_girls", (0)::numeric)), (0)::numeric) AS "remaining_girls",
    GREATEST(((COALESCE(("o"."no_of_boys")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_boys", (0)::numeric)), (0)::numeric) AS "remaining_boys",
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE(("o"."no_of_teacher_women")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_teacher_women", (0)::numeric)), (0)::numeric)
        END AS "remaining_teacher_women",
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE(("o"."no_of_teacher_men")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_teacher_men", (0)::numeric)), (0)::numeric)
        END AS "remaining_teacher_men",
        CASE
            WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE(("o"."num_drivers")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_driver", (0)::numeric)), (0)::numeric)
        END AS "remaining_driver",
        CASE
            WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE("array_length"("o"."tour_guide", 1), 0))::numeric - COALESCE("booking_stats"."assigned_tour_guide", (0)::numeric)), (0)::numeric)
        END AS "remaining_tour_guide",
    GREATEST((((((("o"."no_of_girls" + "o"."no_of_boys") +
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE (COALESCE(("o"."no_of_teacher_women")::integer, 0) + COALESCE(("o"."no_of_teacher_men")::integer, 0))
        END) +
        CASE
            WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE(("o"."num_drivers")::integer, 0)
        END) +
        CASE
            WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
        END))::numeric - COALESCE("booking_stats"."total_assigned_host", (0)::numeric)), (0)::numeric) AS "total_remaining_host",
    ( SELECT
                CASE
                    WHEN ("count"("fc"."fc_elem") = 0) THEN NULL::"jsonb"[]
                    ELSE "array_agg"("fc"."fc_elem")
                END AS "array_agg"
           FROM ("unnest"("o"."destinations") "u"("dest_elem")
             CROSS JOIN LATERAL "jsonb_array_elements"((("u"."dest_elem")::"jsonb" -> 'family_centers'::"text")) "fc"("fc_elem"))) AS "all_family_centers",
    ( SELECT "array_agg"(DISTINCT TRIM(BOTH '"'::"text" FROM ("coord"."coord_elem")::"text")) AS "array_agg"
           FROM (("unnest"("o"."destinations") "u"("dest_elem")
             CROSS JOIN LATERAL "jsonb_array_elements"((("u"."dest_elem")::"jsonb" -> 'family_centers'::"text")) "fc"("fc_elem"))
             CROSS JOIN LATERAL "jsonb_array_elements"(("fc"."fc_elem" -> 'coordinator_ids'::"text")) "coord"("coord_elem"))) AS "coordinator_ids"
   FROM (((("public"."option" "o"
     LEFT JOIN "public"."customer" "c" ON (("o"."autoid_client" = "c"."autoid_customer")))
     LEFT JOIN "public"."users" "am" ON (("o"."account_manager" = "am"."id")))
     LEFT JOIN LATERAL ( SELECT "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'girl'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_girls",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'boy'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_boys",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'teacher_women'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_teacher_women",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'teacher_men'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_teacher_men",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'driver'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_driver",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'tour_guide'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_tour_guide",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = ANY (ARRAY['girl'::"public"."host_preference", 'boy'::"public"."host_preference", 'teacher_women'::"public"."host_preference", 'teacher_men'::"public"."host_preference", 'driver'::"public"."host_preference", 'tour_guide'::"public"."host_preference"])) THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "total_assigned_host"
           FROM "public"."bookings" "b"
          WHERE ("b"."auto_id_group" = "o"."id")) "booking_stats" ON (true))
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN (( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")) = (0)::numeric) THEN 'pending'::"text"
                    WHEN (( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")) < (((("o"."no_of_girls" + "o"."no_of_boys") +
                    CASE
                        WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
                    END) +
                    CASE
                        WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE(("o"."num_drivers")::integer, 0)
                    END))::numeric) THEN 'partially_assigned'::"text"
                    WHEN ((( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")) = (((("o"."no_of_girls" + "o"."no_of_boys") +
                    CASE
                        WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
                    END) +
                    CASE
                        WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE(("o"."num_drivers")::integer, 0)
                    END))::numeric) AND (( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE (("bookings"."auto_id_group" = "o"."id") AND ("bookings"."host_family_status" = 'confirmed'::"public"."booking_status"))) = ( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")))) THEN 'family_confirmed'::"text"
                    WHEN ((( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")) = (((("o"."no_of_girls" + "o"."no_of_boys") +
                    CASE
                        WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
                    END) +
                    CASE
                        WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE(("o"."num_drivers")::integer, 0)
                    END))::numeric) AND (( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE (("bookings"."auto_id_group" = "o"."id") AND ("bookings"."host_family_status" = 'confirmed'::"public"."booking_status"))) < ( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")))) THEN 'partially_confirmed'::"text"
                    WHEN ((( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")) > 0) AND (( SELECT "count"(*) AS "count"
                       FROM "public"."bookings" "b_inner"
                      WHERE (("b_inner"."auto_id_group" = "o"."id") AND ("b_inner"."host_details" IS NOT NULL) AND ("array_length"("b_inner"."host_details", 1) > 0) AND (NOT (EXISTS ( SELECT 1
                               FROM "unnest"("b_inner"."host_details") "host_detail"("host_detail")
                              WHERE ((("host_detail"."host_detail" ->> 'name'::"text") IS NULL) OR (("host_detail"."host_detail" ->> 'name'::"text") = ''::"text"))))) AND (( SELECT "count"(*) AS "count"
                               FROM "unnest"("b_inner"."host_details") "host_detail"("host_detail")
                              WHERE ((("host_detail"."host_detail" ->> 'name'::"text") IS NOT NULL) AND (("host_detail"."host_detail" ->> 'name'::"text") <> ''::"text"))) = COALESCE("b_inner"."assigned_host", (0)::bigint)))) = ( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."auto_id_group" = "o"."id")))) THEN 'completed'::"text"
                    ELSE 'partially_assigned'::"text"
                END AS "status") "status_analysis" ON (true))
  GROUP BY "o"."id", "c"."first_name", "c"."email", "am"."display_name", "am"."email", "booking_stats"."assigned_girls", "booking_stats"."assigned_boys", "booking_stats"."assigned_teacher_women", "booking_stats"."assigned_teacher_men", "booking_stats"."assigned_driver", "booking_stats"."total_assigned_host", "booking_stats"."assigned_tour_guide", "status_analysis"."status";
CREATE OR REPLACE VIEW "public"."groups_details" WITH ("security_invoker"='on') AS
 SELECT "o"."id",
    "o"."created_date" AS "created_at",
    "o"."group_name",
    "o"."option_number",
    "o"."autoid_client_option",
    "o"."case_no",
    "o"."expired_date",
    "o"."country_code",
    "o"."option_comments",
    "o"."autoid_client" AS "customer_id",
        CASE
            WHEN (("o"."autoid_status_master" = ANY (ARRAY[(388)::bigint, (1043)::bigint])) AND (("o"."expired_date" IS NULL) OR (("o"."expired_date")::"text" = ''::"text") OR (("o"."expired_date")::"date" < CURRENT_DATE))) THEN (1042)::bigint
            ELSE "o"."autoid_status_master"
        END AS "autoid_status_master",
    "m"."code" AS "option_status",
    "master_producttype"."code" AS "product_type_code",
    "o"."autoid_product_type_master",
    "o"."autoid_client_expedient",
    "c"."email" AS "customer_email",
    "am"."email" AS "account_manager_email",
    "c"."first_name" AS "customer_name",
    "o"."teacher_name",
    "o"."school_name",
    "o"."meeting_date" AS "check_in_date",
    "o"."deadline_date" AS "check_out_date",
    ( SELECT
                CASE
                    WHEN ("count"("u"."dest_elem") = 0) THEN NULL::"jsonb"[]
                    ELSE "array_agg"(("u"."dest_elem")::"jsonb")
                END AS "array_agg"
           FROM "unnest"("o"."destinations") "u"("dest_elem")) AS "destinations",
    "o"."total_group",
    "o"."no_of_girls",
    "o"."no_of_boys",
    "o"."no_of_teacher_women",
    "o"."no_of_teacher_men",
    "o"."num_drivers" AS "no_of_driver",
    ( SELECT
                CASE
                    WHEN ("count"("st"."st_elem") = 0) THEN NULL::"jsonb"[]
                    ELSE "array_agg"(("st"."st_elem")::"jsonb")
                END AS "array_agg"
           FROM "unnest"("o"."schedule_time") "st"("st_elem")) AS "schedule_time",
    "o"."adults",
    "o"."extra_picnic",
    "o"."emergency_phone",
    "o"."damage_insurance",
    "o"."liability_insurance",
    "o"."group_observations" AS "notes",
    "o"."teacher_hosting_preference",
    "o"."driver_hosting_preference",
    "o"."tour_guide_hosting_preference",
    "o"."customer_status",
    COALESCE("status_analysis"."status", 'pending'::"text") AS "status",
    "o"."need_tour_guide",
    "o"."tour_guide",
    "o"."account_manager",
    "am"."display_name" AS "account_manager_name",
    "o"."additional_services",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM "public"."groups" "g"
              WHERE ("g"."option_id" = "o"."autoid_client_option"))) THEN true
            ELSE false
        END AS "convert_group",
    (((("o"."no_of_girls" + "o"."no_of_boys") +
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
        END) +
        CASE
            WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE(("o"."num_drivers")::integer, 0)
        END) +
        CASE
            WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
        END) AS "total_host",
    COALESCE("booking_stats"."assigned_girls", (0)::numeric) AS "assigned_girls",
    COALESCE("booking_stats"."assigned_boys", (0)::numeric) AS "assigned_boys",
    COALESCE("booking_stats"."assigned_teacher_women", (0)::numeric) AS "assigned_teacher_women",
    COALESCE("booking_stats"."assigned_teacher_men", (0)::numeric) AS "assigned_teacher_men",
    COALESCE("booking_stats"."assigned_driver", (0)::numeric) AS "assigned_driver",
    COALESCE("booking_stats"."assigned_tour_guide", (0)::numeric) AS "assigned_tour_guide",
    COALESCE("booking_stats"."total_assigned_host", (0)::numeric) AS "total_assigned_host",
    GREATEST(((COALESCE(("o"."no_of_girls")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_girls", (0)::numeric)), (0)::numeric) AS "remaining_girls",
    GREATEST(((COALESCE(("o"."no_of_boys")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_boys", (0)::numeric)), (0)::numeric) AS "remaining_boys",
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE(("o"."no_of_teacher_women")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_teacher_women", (0)::numeric)), (0)::numeric)
        END AS "remaining_teacher_women",
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE(("o"."no_of_teacher_men")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_teacher_men", (0)::numeric)), (0)::numeric)
        END AS "remaining_teacher_men",
        CASE
            WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE(("o"."num_drivers")::integer, 0))::numeric - COALESCE("booking_stats"."assigned_driver", (0)::numeric)), (0)::numeric)
        END AS "remaining_driver",
        CASE
            WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN (0)::numeric
            ELSE GREATEST(((COALESCE("array_length"("o"."tour_guide", 1), 0))::numeric - COALESCE("booking_stats"."assigned_tour_guide", (0)::numeric)), (0)::numeric)
        END AS "remaining_tour_guide",
    GREATEST((((((("o"."no_of_girls" + "o"."no_of_boys") +
        CASE
            WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE (COALESCE(("o"."no_of_teacher_women")::integer, 0) + COALESCE(("o"."no_of_teacher_men")::integer, 0))
        END) +
        CASE
            WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE(("o"."num_drivers")::integer, 0)
        END) +
        CASE
            WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
            ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
        END))::numeric - COALESCE("booking_stats"."total_assigned_host", (0)::numeric)), (0)::numeric) AS "total_remaining_host",
    ( SELECT
                CASE
                    WHEN ("count"("fc"."fc_elem") = 0) THEN NULL::"jsonb"[]
                    ELSE "array_agg"("fc"."fc_elem")
                END AS "array_agg"
           FROM ("unnest"("o"."destinations") "u"("dest_elem")
             CROSS JOIN LATERAL "jsonb_array_elements"((("u"."dest_elem")::"jsonb" -> 'family_centers'::"text")) "fc"("fc_elem"))) AS "all_family_centers",
    ( SELECT "array_agg"(DISTINCT TRIM(BOTH '"'::"text" FROM ("coord"."coord_elem")::"text")) AS "array_agg"
           FROM (("unnest"("o"."destinations") "u"("dest_elem")
             CROSS JOIN LATERAL "jsonb_array_elements"((("u"."dest_elem")::"jsonb" -> 'family_centers'::"text")) "fc"("fc_elem"))
             CROSS JOIN LATERAL "jsonb_array_elements"(("fc"."fc_elem" -> 'coordinator_ids'::"text")) "coord"("coord_elem"))) AS "coordinator_ids"
   FROM (((((("public"."option" "o"
     LEFT JOIN "public"."customer" "c" ON (("o"."autoid_client" = "c"."autoid_customer")))
     LEFT JOIN "public"."users" "am" ON (("o"."account_manager" = "am"."id")))
     LEFT JOIN LATERAL ( SELECT "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'girl'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_girls",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'boy'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_boys",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'teacher_women'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_teacher_women",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'teacher_men'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_teacher_men",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'driver'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_driver",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = 'tour_guide'::"public"."host_preference") THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "assigned_tour_guide",
            "sum"(
                CASE
                    WHEN ("b"."assigned_host_type" = ANY (ARRAY['girl'::"public"."host_preference", 'boy'::"public"."host_preference", 'teacher_women'::"public"."host_preference", 'teacher_men'::"public"."host_preference", 'driver'::"public"."host_preference", 'tour_guide'::"public"."host_preference"])) THEN COALESCE("b"."assigned_host", (0)::bigint)
                    ELSE (0)::bigint
                END) AS "total_assigned_host"
           FROM "public"."bookings" "b"
          WHERE (("b"."group_id" = "o"."id") AND ("b"."host_family_status" <> 'rejected'::"public"."booking_status"))) "booking_stats" ON (true))
     LEFT JOIN "public"."master" "m" ON ((
        CASE
            WHEN (("o"."autoid_status_master" = ANY (ARRAY[(388)::bigint, (1043)::bigint])) AND (("o"."expired_date" IS NULL) OR (("o"."expired_date")::"text" = ''::"text") OR (("o"."expired_date")::"date" < CURRENT_DATE))) THEN (1042)::bigint
            ELSE "o"."autoid_status_master"
        END = "m"."autoid_master")))
     LEFT JOIN "public"."master" "master_producttype" ON (("o"."autoid_product_type_master" = "master_producttype"."autoid_master")))
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN (( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")) = (0)::numeric) THEN 'pending'::"text"
                    WHEN (( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")) < ((((("o"."no_of_girls" + "o"."no_of_boys") +
                    CASE
                        WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
                    END) +
                    CASE
                        WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE(("o"."num_drivers")::integer, 0)
                    END) +
                    CASE
                        WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
                    END))::numeric) THEN 'partially_assigned'::"text"
                    WHEN ((( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")) = ((((("o"."no_of_girls" + "o"."no_of_boys") +
                    CASE
                        WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
                    END) +
                    CASE
                        WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE(("o"."num_drivers")::integer, 0)
                    END) +
                    CASE
                        WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
                    END))::numeric) AND (( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE (("bookings"."group_id" = "o"."id") AND ("bookings"."host_family_status" = 'confirmed'::"public"."booking_status"))) = ( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")))) THEN 'family_confirmed'::"text"
                    WHEN ((( SELECT COALESCE("sum"("bookings"."assigned_host"), (0)::numeric) AS "coalesce"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")) = ((((("o"."no_of_girls" + "o"."no_of_boys") +
                    CASE
                        WHEN ("o"."teacher_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE (("o"."no_of_teacher_women" + "o"."no_of_teacher_men"))::integer
                    END) +
                    CASE
                        WHEN ("o"."driver_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE(("o"."num_drivers")::integer, 0)
                    END) +
                    CASE
                        WHEN ("o"."tour_guide_hosting_preference" = 'hotel'::"text") THEN 0
                        ELSE COALESCE("array_length"("o"."tour_guide", 1), 0)
                    END))::numeric) AND (( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE (("bookings"."group_id" = "o"."id") AND ("bookings"."host_family_status" = 'confirmed'::"public"."booking_status"))) < ( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")))) THEN 'partially_confirmed'::"text"
                    WHEN ((( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")) > 0) AND (( SELECT "count"(*) AS "count"
                       FROM "public"."bookings" "b_inner"
                      WHERE (("b_inner"."group_id" = "o"."id") AND ("b_inner"."host_details" IS NOT NULL) AND ("array_length"("b_inner"."host_details", 1) > 0) AND (NOT (EXISTS ( SELECT 1
                               FROM "unnest"("b_inner"."host_details") "host_detail"("host_detail")
                              WHERE ((("host_detail"."host_detail" ->> 'name'::"text") IS NULL) OR (("host_detail"."host_detail" ->> 'name'::"text") = ''::"text"))))) AND (( SELECT "count"(*) AS "count"
                               FROM "unnest"("b_inner"."host_details") "host_detail"("host_detail")
                              WHERE ((("host_detail"."host_detail" ->> 'name'::"text") IS NOT NULL) AND (("host_detail"."host_detail" ->> 'name'::"text") <> ''::"text"))) = COALESCE("b_inner"."assigned_host", (0)::bigint)))) = ( SELECT "count"(*) AS "count"
                       FROM "public"."bookings"
                      WHERE ("bookings"."group_id" = "o"."id")))) THEN 'completed'::"text"
                    ELSE 'partially_assigned'::"text"
                END AS "status") "status_analysis" ON (true))
  GROUP BY "o"."id", "c"."first_name", "c"."email", "am"."display_name", "am"."email", "booking_stats"."assigned_girls", "booking_stats"."assigned_boys", "booking_stats"."assigned_teacher_women", "booking_stats"."assigned_teacher_men", "booking_stats"."assigned_driver", "booking_stats"."total_assigned_host", "booking_stats"."assigned_tour_guide", "m"."code", "master_producttype"."code", "status_analysis"."status";
CREATE OR REPLACE VIEW "public"."comprehensive_family_details" WITH ("security_invoker"='on') AS
 WITH "user_meeting_points" AS (
         SELECT "h_1"."id" AS "user_id",
            "h_1"."lat",
            "h_1"."lng",
            "round"((COALESCE(( SELECT "min"(((6371)::double precision * "acos"(LEAST((1.0)::double precision, GREATEST(('-1.0'::numeric)::double precision, ((("cos"("radians"("h_1"."lat")) * "cos"("radians"("mp"."lat"))) * "cos"(("radians"("mp"."lng") - "radians"("h_1"."lng")))) + ("sin"("radians"("h_1"."lat")) * "sin"("radians"("mp"."lat"))))))))) AS "min"
                   FROM "public"."meeting_points" "mp"
                  WHERE (("mp"."autoid_familycenter" = "fc_1"."id") AND ("h_1"."lat" IS NOT NULL) AND ("h_1"."lng" IS NOT NULL) AND ("mp"."lat" IS NOT NULL) AND ("mp"."lng" IS NOT NULL))), NULL::double precision))::numeric, 2) AS "distance_to_nearest_meeting_point_km",
            ( SELECT "json_build_object"('id', "nearest_mp"."id", 'name', "nearest_mp"."name", 'address', "nearest_mp"."address", 'lat', "nearest_mp"."lat", 'lng', "nearest_mp"."lng", 'distance_km', "nearest_mp"."distance_km") AS "json_build_object"
                   FROM ( SELECT "mp"."id",
                            "mp"."name",
                            "mp"."address",
                            "mp"."lat",
                            "mp"."lng",
                            "round"(((6371)::numeric * ("acos"(LEAST((1.0)::double precision, GREATEST(('-1.0'::numeric)::double precision, ((("cos"("radians"("h_1"."lat")) * "cos"("radians"("mp"."lat"))) * "cos"(("radians"("mp"."lng") - "radians"("h_1"."lng")))) + ("sin"("radians"("h_1"."lat")) * "sin"("radians"("mp"."lat"))))))))::numeric), 2) AS "distance_km"
                           FROM "public"."meeting_points" "mp"
                          WHERE (("mp"."autoid_familycenter" = "fc_1"."id") AND ("h_1"."lat" IS NOT NULL) AND ("h_1"."lng" IS NOT NULL) AND ("mp"."lat" IS NOT NULL) AND ("mp"."lng" IS NOT NULL))
                          ORDER BY ("round"(((6371)::numeric * ("acos"(LEAST((1.0)::double precision, GREATEST(('-1.0'::numeric)::double precision, ((("cos"("radians"("h_1"."lat")) * "cos"("radians"("mp"."lat"))) * "cos"(("radians"("mp"."lng") - "radians"("h_1"."lng")))) + ("sin"("radians"("h_1"."lat")) * "sin"("radians"("mp"."lat"))))))))::numeric), 2))
                         LIMIT 1) "nearest_mp") AS "nearest_meeting_point"
           FROM ("public"."host_family" "h_1"
             LEFT JOIN "public"."family_centers" "fc_1" ON (("h_1"."family_center_id" = "fc_1"."id")))
        )
 SELECT "h"."id" AS "family_id",
    "h"."created_at" AS "user_created_at",
    "h"."wife_name" AS "display_name",
    "h"."wife_email" AS "email",
    "h"."wife_phone" AS "phone_number",
    "h"."profile_picture",
    "h"."is_profile_completed",
    "h"."current_profile_step",
    "h"."wife_birth_date" AS "date_of_birth",
    "h"."dni_number",
    "h"."address",
    "h"."lat",
    "h"."lng",
    "h"."people_live_in_house",
    "h"."smokers",
    "h"."languages_spoken",
    "h"."disability" AS "disabilities_or_illnesses",
    "h"."accepts_allergies",
    "h"."accepts_special_care",
    "h"."accompany" AS "accompany_the_student",
    "h"."has_vehicle" AS "has_a_car",
    "h"."criminal_record",
    "h"."criminal_record_image",
    "h"."sexual_offenses",
    "h"."sexual_offenses_image",
    "h"."iban",
    "h"."active",
        CASE
            WHEN ("h"."account_verification_status" = 'active'::"public"."verification_status") THEN true
            ELSE false
        END AS "account_verified",
    "h"."blocked_dates",
    "h"."account_verification_status",
    "h"."account_rejection_message",
    "h"."coordinator_id",
    "h"."family_center_id",
    "h"."last_check_in_date",
    "cd"."name" AS "coordinator_name",
    "fc"."name" AS "family_center_name",
    "h"."has_children",
    "h"."children_details",
    "h"."has_animals" AS "has_pets",
    "h"."pets_details",
    "h"."guest_preferences",
    "h"."guest_preferences" AS "host_preference",
    "h"."autoid_family",
    "h"."wife_profession_id",
    "h"."wife_marital_status_id",
    "h"."wife_birth_year",
    "h"."wife_mobile",
    "h"."has_vehicle",
    "h"."husband_name",
    "h"."husband_profession_id",
    "h"."husband_birth_year",
    "h"."husband_mobile",
    "h"."husband_email",
    "h"."street_type_id",
    "h"."street_name",
    "h"."street_number",
    "h"."staircase",
    "h"."floor",
    "h"."door",
    "h"."postal_code",
    "h"."town",
    "h"."county_id",
    "h"."province_id",
    "h"."country_id",
    "h"."has_people",
    "h"."other_people",
    "h"."has_animals",
    "h"."domestic_animals",
    "h"."disability",
    "h"."background",
    "h"."evaluation",
    "h"."bic",
    "h"."num_people",
    "h"."accompany",
    "h"."accommodation_desc_text",
    "h"."distance_on_foot",
    "h"."distance_by_car",
    "h"."notes",
    "h"."country_code",
    "h"."hostfamily_uid",
    "h"."husband_birth_date",
    "m"."code" AS "marital_status_code",
    "address_edit"."address_edit_status",
    "address_edit"."address_edit_new_value",
    "hosting_edit"."hosting_capacity_edit_status",
    "hosting_edit"."hosting_capacity_edit_new_value",
    "p"."id" AS "partner_id",
    "p"."name" AS "partner_name",
    "p"."date_of_birth" AS "partner_date_of_birth",
    "p"."national_id" AS "partner_national_id",
    "p"."phone_number" AS "partner_phone_number",
    "p"."email" AS "partner_email",
    "rr"."id" AS "house_id",
    "rr"."created_at" AS "house_created_at",
    "rr"."residence_type",
    "rr"."elevator",
    (COALESCE("room_summary"."calculated_capacity", ("rr"."hosting_capacity")::bigint))::"text" AS "hosting_capacity",
    "rr"."rooms",
    "rr"."bathroom_image",
    "rr"."livingroom_image",
    "rr"."kitchen_image",
    "rr"."other_amenities",
    "rr"."bathroom_images",
    "rr"."livingroom_images",
    "rr"."kitchen_images",
    "rr"."other_area_images",
    "ump"."distance_to_nearest_meeting_point_km",
    ("ump"."nearest_meeting_point")::"jsonb" AS "nearest_meeting_point",
    ( SELECT COALESCE("array_agg"("subquery"."elem")) AS "coalesce"
           FROM ( SELECT "json_build_object"('booking_id', "bd"."booking_id", 'created_at', "bd"."booking_created_at", 'updated_at', "bd"."booking_updated_at", 'host_family_id', "bd"."host_family_id", 'host_family_name', "h"."display_name", 'room_id', "bd"."room_id", 'check_in_date', "bd"."check_in_date", 'check_out_date', "bd"."check_out_date", 'host_family_status', "bd"."booking_status", 'total_price', "bd"."total_price", 'allergies', "bd"."allergies", 'comments', "bd"."comments", 'extra_picnic', "bd"."extra_picnic", 'family_centers_id', "bd"."family_centers_id", 'assigned_at', "bd"."assigned_at", 'assigned_by', "bd"."assigned_by", 'assigned_host', "bd"."assigned_host", 'assigned_host_type', "bd"."assigned_host_type", 'host_details', "bd"."host_details", 'group_id', "bd"."group_id", 'booking_duration_days', "bd"."booking_duration_days") AS "elem"
                   FROM "public"."booking_details" "bd"
                  WHERE (("h"."id" = "bd"."host_family_id") AND ("bd"."booking_id" IS NOT NULL))) "subquery") AS "my_bookings"
   FROM ((((((((("public"."host_family" "h"
     LEFT JOIN "user_meeting_points" "ump" ON (("h"."id" = "ump"."user_id")))
     LEFT JOIN "public"."partner_details" "p" ON (("h"."id" = "p"."id")))
     LEFT JOIN "public"."room_records" "rr" ON (("h"."id" = "rr"."family_id")))
     LEFT JOIN LATERAL ( SELECT "sum"((("room_elem"."value" ->> 'bedroom_type'::"text"))::integer) AS "calculated_capacity"
           FROM "jsonb_array_elements"(((('['::"text" || "array_to_string"("rr"."rooms", ','::"text")) || ']'::"text"))::"jsonb") "room_elem"("value")
          WHERE ("room_elem"."value" ? 'bedroom_type'::"text")) "room_summary" ON (true))
     LEFT JOIN "public"."coordinators" "cd" ON (("cd"."autoId_familia_coordinator" = "h"."coordinator_id")))
     LEFT JOIN "public"."family_centers" "fc" ON (("h"."family_center_id" = "fc"."id")))
     LEFT JOIN "public"."master" "m" ON (("h"."wife_marital_status_id" = "m"."autoid_master")))
     LEFT JOIN LATERAL ( SELECT "per"."status" AS "address_edit_status",
            "per"."new_value" AS "address_edit_new_value"
           FROM "public"."profile_edit_requests" "per"
          WHERE (("per"."hostfamily_id" = "h"."id") AND ("per"."field_name" = 'address'::"text"))
          ORDER BY "per"."created_at" DESC
         LIMIT 1) "address_edit" ON (true))
     LEFT JOIN LATERAL ( SELECT "per"."status" AS "hosting_capacity_edit_status",
            "per"."hosting_capacity_new" AS "hosting_capacity_edit_new_value"
           FROM "public"."profile_edit_requests" "per"
          WHERE (("per"."hostfamily_id" = "h"."id") AND ("per"."field_name" = 'hosting_capacity'::"text"))
          ORDER BY "per"."created_at" DESC
         LIMIT 1) "hosting_edit" ON (true))
  GROUP BY "h"."id", "h"."created_at", "h"."wife_name", "h"."wife_email", "h"."phone_number", "h"."profile_picture", "h"."is_profile_completed", "h"."current_profile_step", "h"."wife_birth_date", "h"."dni_number", "h"."address", "h"."lat", "h"."lng", "h"."people_live_in_house", "h"."smokers", "h"."languages_spoken", "h"."disability", "h"."accepts_allergies", "h"."accepts_special_care", "h"."accompany", "h"."has_vehicle", "h"."criminal_record", "h"."criminal_record_image", "h"."sexual_offenses", "h"."sexual_offenses_image", "h"."iban", "h"."account_verified", "h"."account_verification_status", "h"."active", "h"."account_rejection_message", "h"."coordinator_id", "h"."family_center_id", "h"."last_check_in_date", "cd"."name", "fc"."name", "h"."autoid_family", "h"."wife_profession_id", "h"."wife_marital_status_id", "h"."wife_birth_year", "h"."wife_mobile", "h"."husband_name", "h"."husband_profession_id", "h"."husband_birth_year", "h"."husband_mobile", "h"."husband_email", "h"."street_type_id", "h"."street_name", "h"."street_number", "h"."staircase", "h"."floor", "h"."door", "h"."postal_code", "h"."town", "h"."county_id", "h"."province_id", "h"."country_id", "h"."has_people", "h"."other_people", "h"."country_code", "h"."has_animals", "h"."domestic_animals", "h"."background", "h"."evaluation", "h"."bic", "h"."num_people", "h"."accommodation_desc_text", "h"."distance_on_foot", "h"."distance_by_car", "h"."hostfamily_uid", "h"."husband_birth_date", "h"."notes", "m"."code", "address_edit"."address_edit_new_value", "address_edit"."address_edit_status", "hosting_edit"."hosting_capacity_edit_status", "hosting_edit"."hosting_capacity_edit_new_value", "h"."has_children", "h"."children_details", "h"."pets_details", "h"."guest_preferences", "p"."id", "p"."name", "p"."date_of_birth", "p"."national_id", "p"."phone_number", "p"."email", "rr"."id", "rr"."created_at", "rr"."residence_type", "rr"."elevator", "rr"."host_preference", "rr"."bathroom_image", "rr"."livingroom_image", "rr"."kitchen_image", "rr"."other_amenities", "rr"."bathroom_images", "rr"."livingroom_images", "rr"."kitchen_images", "rr"."other_area_images", "ump"."distance_to_nearest_meeting_point_km", ("ump"."nearest_meeting_point")::"jsonb", "room_summary"."calculated_capacity";
CREATE OR REPLACE TRIGGER "coodinators_webhook_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."coordinators" FOR EACH ROW EXECUTE FUNCTION "public"."call_coodinators_webhook"();
CREATE OR REPLACE TRIGGER "customer_webhook_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."customer" FOR EACH ROW EXECUTE FUNCTION "public"."call_customer_webhook"();
CREATE OR REPLACE TRIGGER "family_centers_webhook_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."family_centers" FOR EACH ROW EXECUTE FUNCTION "public"."call_family_center_webhook"();
CREATE OR REPLACE TRIGGER "host_family_webhook_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."host_family" FOR EACH ROW EXECUTE FUNCTION "public"."call_host_family_webhook"();
CREATE OR REPLACE TRIGGER "meeting_points_webhook_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."meeting_points" FOR EACH ROW EXECUTE FUNCTION "public"."call_meeting_points_webhook"();
CREATE OR REPLACE TRIGGER "on_public_user_deleted" AFTER DELETE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."handle_public_user_deleted"();
CREATE OR REPLACE TRIGGER "option_webhook_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."option" FOR EACH ROW EXECUTE FUNCTION "public"."call_option_webhook"();
CREATE OR REPLACE TRIGGER "trigger_update_coordinator_uid" AFTER INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."update_coordinator_uid"();
CREATE OR REPLACE TRIGGER "trigger_update_host_family_distances" BEFORE INSERT OR UPDATE OF "family_center_id" ON "public"."host_family" FOR EACH ROW EXECUTE FUNCTION "public"."update_host_family_distances"();
CREATE OR REPLACE TRIGGER "trigger_update_host_family_distances_insert" AFTER INSERT ON "public"."host_family" FOR EACH ROW EXECUTE FUNCTION "public"."update_host_family_distances"();
CREATE OR REPLACE TRIGGER "trigger_update_host_family_distances_update" BEFORE UPDATE OF "family_center_id" ON "public"."host_family" FOR EACH ROW EXECUTE FUNCTION "public"."update_host_family_distances"();
ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."option"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_host_family_id_fkey" FOREIGN KEY ("host_family_id") REFERENCES "public"."host_family"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_table_house_id_fkey" FOREIGN KEY ("room_id") REFERENCES "public"."room_records"("id");
ALTER TABLE ONLY "public"."contact_us"
    ADD CONSTRAINT "contact_us_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."coordinators"
    ADD CONSTRAINT "coodinators_autoid_master_street_type_fkey" FOREIGN KEY ("autoid_master_street_type") REFERENCES "public"."road_type"("autoid_master");
ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_account_manager_fkey" FOREIGN KEY ("account_manager") REFERENCES "public"."users"("id");
ALTER TABLE ONLY "public"."meeting_points"
    ADD CONSTRAINT "meeting_points_autoid_familycenter_fkey" FOREIGN KEY ("autoid_familycenter") REFERENCES "public"."family_centers"("AutoIdFamiliaCentre") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."partner_details"
    ADD CONSTRAINT "partner_details_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."profile_edit_requests"
    ADD CONSTRAINT "profile_edit_requests_hostfamily_id_fkey" FOREIGN KEY ("hostfamily_id") REFERENCES "public"."host_family"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_account_manager_id_fkey" FOREIGN KEY ("account_manager_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_coordinator_id_fkey" FOREIGN KEY ("coordinator_id") REFERENCES "public"."users"("id") ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
CREATE POLICY "All Access" ON "public"."bookings" USING (true) WITH CHECK (true);
CREATE POLICY "All Access" ON "public"."groups" USING (true) WITH CHECK (true);
CREATE POLICY "All Access Of Users " ON "public"."users" USING (true) WITH CHECK (true);
CREATE POLICY "Enable all access for authenticated users" ON "public"."feedback" TO "authenticated" USING (true) WITH CHECK (true);
CREATE POLICY "Enable all access for authenticated users" ON "public"."partner_details" USING (true) WITH CHECK (true);
CREATE POLICY "Enable all access for authenticated users" ON "public"."room_records" TO "authenticated" USING (true) WITH CHECK (true);
CREATE POLICY "Enable insert for authenticated users only" ON "public"."contact_us" TO "authenticated" USING (true) WITH CHECK (true);
CREATE POLICY "Enable read access for all users" ON "public"."room_records" FOR SELECT USING (true);
ALTER TABLE "public"."assigned_role" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "assigned_role" ON "public"."assigned_role" USING (true) WITH CHECK (true);
ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."client_expedient_option_family_center_family_stays" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "client_expedient_option_family_center_family_stays" ON "public"."client_expedient_option_family_center_family_stays" USING (true) WITH CHECK (true);
ALTER TABLE "public"."client_option_family_centers" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "client_option_family_centers" ON "public"."client_option_family_centers" USING (true) WITH CHECK (true);
ALTER TABLE "public"."contact_us" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "coodinator" ON "public"."coordinators" USING (true) WITH CHECK (true);
ALTER TABLE "public"."coordinators" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."customer" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customer" ON "public"."customer" USING (true) WITH CHECK (true);
CREATE POLICY "destination" ON "public"."destinations" USING (true) WITH CHECK (true);
ALTER TABLE "public"."destinations" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "familyCenter" ON "public"."family_centers" USING (true) WITH CHECK (true);
ALTER TABLE "public"."family_centers" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."feedback" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."groups" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."host_family" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "host_family" ON "public"."host_family" USING (true) WITH CHECK (true);
ALTER TABLE "public"."master" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "master" ON "public"."master" USING (true) WITH CHECK (true);
CREATE POLICY "master_comara" ON "public"."master_comarca" USING (true) WITH CHECK (true);
ALTER TABLE "public"."master_comarca" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."master_country" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "master_country" ON "public"."master_country" USING (true) WITH CHECK (true);
ALTER TABLE "public"."master_postal_code" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "master_postal_code" ON "public"."master_postal_code" USING (true) WITH CHECK (true);
ALTER TABLE "public"."master_province" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."meeting_points" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "mettingpoints" ON "public"."meeting_points" USING (true) WITH CHECK (true);
ALTER TABLE "public"."notification" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "notification" ON "public"."notification" USING (true) WITH CHECK (true);
ALTER TABLE "public"."option" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "option" ON "public"."option" USING (true) WITH CHECK (true);
ALTER TABLE "public"."partner_details" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profile_edit_control" ON "public"."profile_edit_requests" USING (true) WITH CHECK (true);
ALTER TABLE "public"."profile_edit_requests" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "province" ON "public"."master_province" USING (true) WITH CHECK (true);
ALTER TABLE "public"."road_type" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "road_type" ON "public"."road_type" USING (true) WITH CHECK (true);
ALTER TABLE "public"."room_records" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."wife_marital_status" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wife_marital_status" ON "public"."wife_marital_status" USING (true) WITH CHECK (true);
ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."assigned_role";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."bookings";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."client_expedient_option_family_center_family_stays";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."client_option_family_centers";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."coordinators";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."customer";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."destinations";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."family_centers";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."groups";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."host_family";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."master";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."master_comarca";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."master_country";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."master_postal_code";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."master_province";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."meeting_points";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notification";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."option";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."partner_details";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."profile_edit_requests";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."road_type";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."room_records";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."users";
ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."wife_marital_status";
GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "service_role";
GRANT ALL ON FUNCTION "public"."calculate_haversine_distance"("lat1" double precision, "lng1" double precision, "lat2" double precision, "lng2" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_haversine_distance"("lat1" double precision, "lng1" double precision, "lat2" double precision, "lng2" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_haversine_distance"("lat1" double precision, "lng1" double precision, "lat2" double precision, "lng2" double precision) TO "service_role";
GRANT ALL ON FUNCTION "public"."call_coodinators_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."call_coodinators_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_coodinators_webhook"() TO "service_role";
GRANT ALL ON FUNCTION "public"."call_customer_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."call_customer_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_customer_webhook"() TO "service_role";
GRANT ALL ON FUNCTION "public"."call_external_webhook"("webhook_url" "text", "data_param" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."call_external_webhook"("webhook_url" "text", "data_param" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_external_webhook"("webhook_url" "text", "data_param" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."call_family_center_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."call_family_center_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_family_center_webhook"() TO "service_role";
GRANT ALL ON FUNCTION "public"."call_host_family_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."call_host_family_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_host_family_webhook"() TO "service_role";
GRANT ALL ON FUNCTION "public"."call_meeting_points_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."call_meeting_points_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_meeting_points_webhook"() TO "service_role";
GRANT ALL ON FUNCTION "public"."call_option_webhook"() TO "anon";
GRANT ALL ON FUNCTION "public"."call_option_webhook"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."call_option_webhook"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_next_master_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_next_master_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_next_master_id"() TO "service_role";
GRANT ALL ON FUNCTION "public"."handle_auth_user_deleted"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_auth_user_deleted"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_auth_user_deleted"() TO "service_role";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";
GRANT ALL ON FUNCTION "public"."handle_public_user_deleted"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_public_user_deleted"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_public_user_deleted"() TO "service_role";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "postgres";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "anon";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "service_role";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "postgres";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "service_role";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "postgres";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "service_role";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "service_role";
GRANT ALL ON FUNCTION "public"."process_family_center_insert"("p_record" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."process_family_center_insert"("p_record" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_family_center_insert"("p_record" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."update_coordinator_uid"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_coordinator_uid"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_coordinator_uid"() TO "service_role";
GRANT ALL ON FUNCTION "public"."update_host_family_distances"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_host_family_distances"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_host_family_distances"() TO "service_role";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "service_role";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "service_role";
GRANT ALL ON TABLE "public"."coordinators" TO "anon";
GRANT ALL ON TABLE "public"."coordinators" TO "authenticated";
GRANT ALL ON TABLE "public"."coordinators" TO "service_role";
GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";
GRANT ALL ON TABLE "public"."admin_details" TO "anon";
GRANT ALL ON TABLE "public"."admin_details" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_details" TO "service_role";
GRANT ALL ON TABLE "public"."assigned_role" TO "anon";
GRANT ALL ON TABLE "public"."assigned_role" TO "authenticated";
GRANT ALL ON TABLE "public"."assigned_role" TO "service_role";
GRANT ALL ON SEQUENCE "public"."assigned_role_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."assigned_role_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."assigned_role_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."bookings" TO "anon";
GRANT ALL ON TABLE "public"."bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."bookings" TO "service_role";
GRANT ALL ON TABLE "public"."customer" TO "anon";
GRANT ALL ON TABLE "public"."customer" TO "authenticated";
GRANT ALL ON TABLE "public"."customer" TO "service_role";
GRANT ALL ON TABLE "public"."family_centers" TO "anon";
GRANT ALL ON TABLE "public"."family_centers" TO "authenticated";
GRANT ALL ON TABLE "public"."family_centers" TO "service_role";
GRANT ALL ON TABLE "public"."groups" TO "anon";
GRANT ALL ON TABLE "public"."groups" TO "authenticated";
GRANT ALL ON TABLE "public"."groups" TO "service_role";
GRANT ALL ON TABLE "public"."host_family" TO "anon";
GRANT ALL ON TABLE "public"."host_family" TO "authenticated";
GRANT ALL ON TABLE "public"."host_family" TO "service_role";
GRANT ALL ON TABLE "public"."option" TO "anon";
GRANT ALL ON TABLE "public"."option" TO "authenticated";
GRANT ALL ON TABLE "public"."option" TO "service_role";
GRANT ALL ON TABLE "public"."booking_details" TO "anon";
GRANT ALL ON TABLE "public"."booking_details" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."bookings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."bookings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."bookings_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."client_expedient_option_family_center_family_stays" TO "anon";
GRANT ALL ON TABLE "public"."client_expedient_option_family_center_family_stays" TO "authenticated";
GRANT ALL ON TABLE "public"."client_expedient_option_family_center_family_stays" TO "service_role";
GRANT ALL ON SEQUENCE "public"."client_expedient_option_family_center_family_stays_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_expedient_option_family_center_family_stays_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_expedient_option_family_center_family_stays_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."client_option_family_centers" TO "anon";
GRANT ALL ON TABLE "public"."client_option_family_centers" TO "authenticated";
GRANT ALL ON TABLE "public"."client_option_family_centers" TO "service_role";
GRANT ALL ON SEQUENCE "public"."client_option_family_centers_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_option_family_centers_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_option_family_centers_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."comprehensive_family_details" TO "anon";
GRANT ALL ON TABLE "public"."comprehensive_family_details" TO "authenticated";
GRANT ALL ON TABLE "public"."comprehensive_family_details" TO "service_role";
GRANT ALL ON TABLE "public"."contact_us" TO "anon";
GRANT ALL ON TABLE "public"."contact_us" TO "authenticated";
GRANT ALL ON TABLE "public"."contact_us" TO "service_role";
GRANT ALL ON SEQUENCE "public"."coodinators_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."coodinators_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."coodinators_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."master" TO "anon";
GRANT ALL ON TABLE "public"."master" TO "authenticated";
GRANT ALL ON TABLE "public"."master" TO "service_role";
GRANT ALL ON TABLE "public"."coordinator_details" TO "anon";
GRANT ALL ON TABLE "public"."coordinator_details" TO "authenticated";
GRANT ALL ON TABLE "public"."coordinator_details" TO "service_role";
GRANT ALL ON TABLE "public"."customer_details" TO "anon";
GRANT ALL ON TABLE "public"."customer_details" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."customer_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."customer_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."customer_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."destinations" TO "anon";
GRANT ALL ON TABLE "public"."destinations" TO "authenticated";
GRANT ALL ON TABLE "public"."destinations" TO "service_role";
GRANT ALL ON TABLE "public"."destination_details" TO "anon";
GRANT ALL ON TABLE "public"."destination_details" TO "authenticated";
GRANT ALL ON TABLE "public"."destination_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."destinations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."destinations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."destinations_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."meeting_points" TO "anon";
GRANT ALL ON TABLE "public"."meeting_points" TO "authenticated";
GRANT ALL ON TABLE "public"."meeting_points" TO "service_role";
GRANT ALL ON TABLE "public"."room_records" TO "anon";
GRANT ALL ON TABLE "public"."room_records" TO "authenticated";
GRANT ALL ON TABLE "public"."room_records" TO "service_role";
GRANT ALL ON TABLE "public"."family_centers_details" TO "anon";
GRANT ALL ON TABLE "public"."family_centers_details" TO "authenticated";
GRANT ALL ON TABLE "public"."family_centers_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."family_centers_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."family_centers_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."family_centers_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";
GRANT ALL ON SEQUENCE "public"."feedback_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."feedback_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."feedback_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."groups_details" TO "anon";
GRANT ALL ON TABLE "public"."groups_details" TO "authenticated";
GRANT ALL ON TABLE "public"."groups_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."groups_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."groups_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."groups_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."host_family_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."host_family_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."host_family_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."master_comarca" TO "anon";
GRANT ALL ON TABLE "public"."master_comarca" TO "authenticated";
GRANT ALL ON TABLE "public"."master_comarca" TO "service_role";
GRANT ALL ON SEQUENCE "public"."master_comarca_comarca_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."master_comarca_comarca_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."master_comarca_comarca_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."master_country" TO "anon";
GRANT ALL ON TABLE "public"."master_country" TO "authenticated";
GRANT ALL ON TABLE "public"."master_country" TO "service_role";
GRANT ALL ON SEQUENCE "public"."master_country_id_pais_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."master_country_id_pais_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."master_country_id_pais_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."master_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."master_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."master_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."master_postal_code" TO "anon";
GRANT ALL ON TABLE "public"."master_postal_code" TO "authenticated";
GRANT ALL ON TABLE "public"."master_postal_code" TO "service_role";
GRANT ALL ON SEQUENCE "public"."master_postal_code_postal_code_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."master_postal_code_postal_code_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."master_postal_code_postal_code_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."master_province" TO "anon";
GRANT ALL ON TABLE "public"."master_province" TO "authenticated";
GRANT ALL ON TABLE "public"."master_province" TO "service_role";
GRANT ALL ON TABLE "public"."meeting_point_details" TO "anon";
GRANT ALL ON TABLE "public"."meeting_point_details" TO "authenticated";
GRANT ALL ON TABLE "public"."meeting_point_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."meeting_points_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."meeting_points_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."meeting_points_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."notification" TO "anon";
GRANT ALL ON TABLE "public"."notification" TO "authenticated";
GRANT ALL ON TABLE "public"."notification" TO "service_role";
GRANT ALL ON SEQUENCE "public"."notification_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notification_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notification_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."option_details" TO "anon";
GRANT ALL ON TABLE "public"."option_details" TO "authenticated";
GRANT ALL ON TABLE "public"."option_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."option_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."option_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."option_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."partner_details" TO "anon";
GRANT ALL ON TABLE "public"."partner_details" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_details" TO "service_role";
GRANT ALL ON SEQUENCE "public"."partner_details_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."partner_details_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."partner_details_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."postal_code_view" TO "anon";
GRANT ALL ON TABLE "public"."postal_code_view" TO "authenticated";
GRANT ALL ON TABLE "public"."postal_code_view" TO "service_role";
GRANT ALL ON TABLE "public"."profile_edit_requests" TO "anon";
GRANT ALL ON TABLE "public"."profile_edit_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_edit_requests" TO "service_role";
GRANT ALL ON TABLE "public"."profile_edit_requests_view" TO "anon";
GRANT ALL ON TABLE "public"."profile_edit_requests_view" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_edit_requests_view" TO "service_role";
GRANT ALL ON SEQUENCE "public"."province_province_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."province_province_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."province_province_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."road_type" TO "anon";
GRANT ALL ON TABLE "public"."road_type" TO "authenticated";
GRANT ALL ON TABLE "public"."road_type" TO "service_role";
GRANT ALL ON SEQUENCE "public"."road_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."road_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."road_type_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."rooms_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rooms_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rooms_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."user_details" TO "anon";
GRANT ALL ON TABLE "public"."user_details" TO "authenticated";
GRANT ALL ON TABLE "public"."user_details" TO "service_role";
GRANT ALL ON TABLE "public"."webhook_queue" TO "anon";
GRANT ALL ON TABLE "public"."webhook_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_queue" TO "service_role";
GRANT ALL ON SEQUENCE "public"."webhook_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."webhook_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."webhook_queue_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."wife_marital_status" TO "anon";
GRANT ALL ON TABLE "public"."wife_marital_status" TO "authenticated";
GRANT ALL ON TABLE "public"."wife_marital_status" TO "service_role";
GRANT ALL ON SEQUENCE "public"."wife_marital_status_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."wife_marital_status_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."wife_marital_status_id_seq" TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";
drop extension if exists "pg_net";
create extension if not exists "pg_net" with schema "public";
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
CREATE TRIGGER on_auth_user_deleted AFTER DELETE ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_auth_user_deleted();
create policy "Allow authenticated uploads"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'home-images'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy "Allow public reading of images"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'home-images'::text));
create policy "public_read 12pyejq_0"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using ((bucket_id = 'home-images'::text));
create policy "public_read 12pyejq_1"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check ((bucket_id = 'home-images'::text));
create policy "public_read 12pyejq_2"
  on "storage"."objects"
  as permissive
  for update
  to authenticated
using ((bucket_id = 'home-images'::text));
create policy "public_read 12pyejq_3"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using ((bucket_id = 'home-images'::text));
create policy "public_read 8yg8gq_0"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using ((bucket_id = 'profile-picture'::text));
create policy "public_read 8yg8gq_1"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check ((bucket_id = 'profile-picture'::text));
create policy "public_read 8yg8gq_2"
  on "storage"."objects"
  as permissive
  for update
  to authenticated
using ((bucket_id = 'profile-picture'::text));
create policy "public_read 8yg8gq_3"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using ((bucket_id = 'profile-picture'::text));
