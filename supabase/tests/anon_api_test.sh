#!/usr/bin/env bash
# Anon session over the real API: grants + RLS + PostgREST together.
# A missing policy fails open quietly, so this has to be evidence, not reasoning.
URL="https://drstmntdbmacdplhjvmx.supabase.co/rest/v1"
KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRyc3RtbnRkYm1hY2RwbGhqdm14Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2MzMwMDEsImV4cCI6MjEwMjIwOTAwMX0.319PV9Prn8q6qurIMG_SHk63EoRQCv6tkGn_0fiwo7A"
FID="45bf04ec-aa83-492b-893c-f1de59c27eba"
H=(-H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json")
pass=0; fail=0
chk(){ # label expected_regex actual
  if [[ "$3" =~ $2 ]]; then echo "  PASS  $1  ($3)"; pass=$((pass+1));
  else echo "  FAIL  $1  expected $2, got: $3"; fail=$((fail+1)); fi; }

echo "READS — anon should see everything"
for t in structures features feature_values findings cleared_findings review \
         route_extents hpms_routes county_codes ingest_runs review_history \
         value_divergence feature_resolved feature_value_resolved finding_current \
         structure_status data_vintage county_geojson structure_snbi; do
  code=$(curl -s -o /tmp/r.json -w '%{http_code}' "${H[@]}" "$URL/$t?select=*&limit=1")
  chk "SELECT $t" '^200$' "$code"
done

echo
echo "WRITES — anon should be refused on every table, by grant not by silence"
w(){ curl -s -o /tmp/w.json -w '%{http_code}' "${H[@]}" -X "$1" "$URL/$2" ${3:+-d "$3"}; }
chk "INSERT structures"       '^40[13]$' "$(w POST structures '{"structure_number":"HACK1"}')"
chk "INSERT features"         '^40[13]$' "$(w POST features   "{\"structure_number\":\"APITEST\",\"designation\":\"H09\",\"location_type\":\"C\"}")"
chk "INSERT feature_values"   '^40[13]$' "$(w POST feature_values "{\"feature_id\":\"$FID\",\"field\":\"BH06\",\"source\":\"REVIEWED\",\"value_text\":\"99999999999\"}")"
chk "INSERT findings"         '^40[13]$' "$(w POST findings   "{\"feature_id\":\"$FID\",\"rule_id\":\"FAKE\",\"severity\":\"note\"}")"
chk "INSERT cleared_findings" '^40[13]$' "$(w POST cleared_findings "{\"feature_id\":\"$FID\",\"rule_id\":\"BH06_3_HPMS\",\"action\":\"clear\"}")"
chk "INSERT review"           '^40[13]$' "$(w POST review     "{\"feature_id\":\"$FID\",\"status\":\"fixed\"}")"
chk "INSERT review_history"   '^40[13]$' "$(w POST review_history '{"table_name":"x","row_id":"1","operation":"INSERT"}')"
chk "INSERT hpms_routes"      '^40[13]$' "$(w POST hpms_routes '{"hpms_year":2024,"route_id":"X"}')"
chk "INSERT route_extents"    '^40[13]$' "$(w POST route_extents '{"route_id":"X","min_mp":0,"max_mp":1}')"
chk "INSERT county_codes"     '^40[13]$' "$(w POST county_codes '{"sap_code":"999","county_name":"NOWHERE"}')"
chk "INSERT ingest_runs"      '^40[13]$' "$(w POST ingest_runs '{"source_service":"forged"}')"
chk "UPDATE feature_values"   '^40[13]$' "$(w PATCH "feature_values?field=eq.BH07" '{"value_num":9.9}')"
chk "UPDATE structures"       '^40[13]$' "$(w PATCH "structures?structure_number=eq.APITEST" '{"county_name":"WAKE"}')"
chk "DELETE feature_values"   '^40[13]$' "$(w DELETE "feature_values?field=eq.BH07")"
chk "DELETE structures"       '^40[13]$' "$(w DELETE "structures?structure_number=eq.APITEST")"
chk "DELETE review_history"   '^40[13]$' "$(w DELETE "review_history?id=gt.0")"
chk "INSERT value_divergence" '^40[13]$' "$(w POST value_divergence "{\"feature_id\":\"$FID\",\"field\":\"BH06\"}")"
chk "UPDATE county_geojson"   '^40[13]$' "$(w PATCH "county_geojson?sap_code=eq.060" '{"county_name":"NOWHERE"}')"

echo
echo "THE INGEST TOKEN — readable by nobody, and it must not merely be empty"
code=$(curl -s -o /tmp/s.json -w '%{http_code}' "${H[@]}" "$URL/ingest_secret?select=*")
body=$(cat /tmp/s.json)
chk "SELECT ingest_secret is refused or returns nothing" '^(200|40[13])$' "$code"
chk "...and no token comes back" '^\[\]$|permission denied|^$' "$body"
chk "start an ingest without the token" '^40[0-9]$' \
    "$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST \
       "https://drstmntdbmacdplhjvmx.supabase.co/functions/v1/ingest-counties" -d '{}')"
chk "call trigger_ingest as anon" '^40[013]$' "$(w POST rpc/trigger_ingest '{"p_source":"bridges"}')"

echo
echo "the refusal message anon actually gets:"
curl -s "${H[@]}" -X POST "$URL/feature_values" \
  -d "{\"feature_id\":\"$FID\",\"field\":\"BH06\",\"source\":\"REVIEWED\",\"value_text\":\"9\"}" | head -c 300
echo; echo
echo "and nothing moved:"
curl -s "${H[@]}" "$URL/feature_values?select=field,source,value_text,value_num&order=field" | head -c 400
echo; echo
echo "$pass passed, $fail failed"
