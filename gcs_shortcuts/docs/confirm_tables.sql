SELECT 
  t.table_name,
  t.table_type,
  opt.option_value AS metadata_location,
  -- Extract bucket name from the metadata path
  REGEXP_EXTRACT(opt.option_value, r'gs://([^/]+)/') AS gcs_bucket,
  -- It's Iceberg if it has a metadata_location option
  CASE WHEN opt.option_name = 'metadata_location' THEN 'ICEBERG' ELSE 'OTHER' END AS table_format
FROM `gen-lang-client-0875336337.consulting.INFORMATION_SCHEMA.TABLES` t
LEFT JOIN `gen-lang-client-0875336337.consulting.INFORMATION_SCHEMA.TABLE_OPTIONS` opt
  ON t.table_name = opt.table_name 
  AND opt.option_name = 'metadata_location'
ORDER BY t.table_name