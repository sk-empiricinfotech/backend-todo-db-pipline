drop view if exists "public"."postal_code_view";

alter table "public"."master_country" drop column "state_counts";

create or replace view "public"."postal_code_view" as  SELECT pc.postal_code_id,
    pc.population_name,
    pc.postal_code,
    pc.locality,
    pc.municipality_code_ine,
    pc.county_id,
    c.descripcio AS county_description,
    pc.province_id,
    p.description AS province_description,
    pc.country_id,
    co.description AS country_description,
    co."ISO3166-1-1" AS iso3166_1_1,
    co."ISO3166-1-2" AS iso3166_1_2,
    co."ISO3166-1-3" AS iso3166_1_3
   FROM (((public.master_postal_code pc
     LEFT JOIN public.master_comarca c ON ((pc.county_id = c.comarca_id)))
     LEFT JOIN public.master_province p ON ((pc.province_id = p.province_id)))
     LEFT JOIN public.master_country co ON ((pc.country_id = co.id_pais)));



