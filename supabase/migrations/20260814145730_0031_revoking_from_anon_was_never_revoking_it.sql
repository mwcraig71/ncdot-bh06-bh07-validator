-- ============================================================================
-- "revoke execute ... from anon" has been doing nothing since migration 0026.
--
-- Postgres grants EXECUTE on every new function to PUBLIC. Revoking it from
-- anon removes a grant anon never separately held, and leaves the PUBLIC one
-- standing - so every write function written since the field-capture work has
-- been callable by an anonymous visitor. Checked, not assumed:
--
--   has_function_privilege('anon','approve_proposal(uuid,snbi_field,text)','execute')
--   -> true
--
-- Nothing was exploitable through it. Every one of these functions asks
-- is_approver() or current_actor() first and raises before it touches a row,
-- and current_actor() reads the JWT, which an anonymous caller does not have.
-- The damage was that the ACL said something false: reading the schema, you
-- would conclude anon had been shut out of the write path, and it had not
-- been. A permission that is enforced only inside the function body is one
-- refactor away from not being enforced at all.
--
-- So: revoke from PUBLIC, which is what was meant every time, and re-state the
-- two roles that should hold it. The read-only helpers - current_actor,
-- is_approver, jwt_role, carries_highway, snbi_designation,
-- parse_publication_date - keep their public grant deliberately. They answer
-- questions about the caller or decode a published code, and the tool calls
-- them signed out.
-- ============================================================================

revoke execute on function approve_proposal(uuid, snbi_field, text)          from public;
revoke execute on function reject_proposal(uuid, snbi_field, text)           from public;
revoke execute on function propose_value(text, text, snbi_field, text, text, feature_location, text) from public;
revoke execute on function propose_feature_removal(text, text, text)         from public;
revoke execute on function decide_feature_removal(uuid, boolean, text)       from public;
revoke execute on function grant_approver(text, text)                        from public;
revoke execute on function revoke_approver(uuid, text)                       from public;
revoke execute on function renumber_features(text)                           from public;
revoke execute on function check_designation_rules(text)                     from public;

grant execute on function approve_proposal(uuid, snbi_field, text),
                          reject_proposal(uuid, snbi_field, text),
                          propose_value(text, text, snbi_field, text, text, feature_location, text),
                          propose_feature_removal(text, text, text),
                          decide_feature_removal(uuid, boolean, text),
                          grant_approver(text, text),
                          revoke_approver(uuid, text),
                          renumber_features(text),
                          check_designation_rules(text)
  to authenticated, service_role;
