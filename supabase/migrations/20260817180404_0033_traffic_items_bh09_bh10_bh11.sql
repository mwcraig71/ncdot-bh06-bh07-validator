-- ============================================================================
-- Traffic: B.H.09, B.H.10 and B.H.11, and where the numbers actually come from.
--
-- The AADT on NCDOT's bridge record is not a measurement. Checked in
-- Mecklenburg: of 355 structures carrying an AADT with a count station on the
-- same route within half a mile, 295 - 83% - equal the station's value
-- exactly, median difference 0.0%. It is a copy. What it does not carry is the
-- YEAR it was copied, which is the whole of B.H.11, and 11,016 of 23,022
-- structures carry no AADT at all.
--
-- So the traffic data is ingested from its own source and the three items are
-- derived per feature, the same way BH06/BH07 are:
--
--   * STATIONS are the primary source. 48,687 of them, a value per year from
--     2002 to 2024, two-way totals, keyed on the 11-digit LRS Route ID - the
--     same key BH06 is. The 2024 release was published in September 2025.
--
--   * SEGMENTS are how a bridge finds its station. They are linear-referenced
--     on RouteID + BeginMP/EndMP, so a feature's BH06/BH07 pair lands in one
--     directly, and each carries a TMS_ID that resolves to a station 97.8% of
--     the time. Their own AADT values are older - measured, not assumed: 91% of
--     them equal the station's 2022 figure - so they are used for ASSOCIATION
--     and for the truck share, not for the total.
--
--   * PROBE ESTIMATES cover the roads no station governs, which in Mecklenburg
--     is two thirds of the inventory. Every one carries a 95% confidence
--     interval, which is the only reason a modelled number can be reported
--     honestly beside a counted one.
--
-- B.H.10 is the awkward one. There is no dated truck series anywhere - trucks
-- exist only on the segmentation, at its own older vintage. So the truck COUNT
-- is not carried forward; the truck SHARE is, applied to the current total.
-- Share moves far more slowly than volume, and every derived value records the
-- year its share came from, so the derivation is legible rather than implied.
-- ============================================================================

alter type snbi_field add value if not exists 'BH09';
alter type snbi_field add value if not exists 'BH10';
alter type snbi_field add value if not exists 'BH11';
