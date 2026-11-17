import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";
import { createProjectDeletionHandler } from "./handler.mjs";

const sites=["https://maxivisionmedia-sudo.github.io/dydem-web/",...(Deno.env.get("DYDEM_SITE_URL")||"").split(",")];
const origins=new Set(sites.map(site=>{try{return new URL(site.trim()).origin}catch{return ""}}).filter(Boolean));
Deno.serve(createProjectDeletionHandler({createClient,origins,
 url:Deno.env.get("SUPABASE_URL")||"",anon:Deno.env.get("SUPABASE_ANON_KEY")||"",
 secret:Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||""}));
