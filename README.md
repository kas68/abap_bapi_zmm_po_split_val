# ZMM_PO_SPLIT_VAL – Default valuation type on PO items

Implementation of BAdI `ME_PROCESS_PO_CUST` that fills the valuation type
(`BWTAR`) of purchase order items for split-valuated materials, based on the
custom table `ZPTP_301_VALTYPE`.

Report `ZPTP_PO_SPLIT_VAL_UPDATE` sets the valuation type again on open PO items
(no history, no inbound delivery) from the same table, for the fiscal year of
the run date or of a key date. Mainly for background jobs.
Optionally it also checks (without changing them) the output items of open
production orders without goods receipt against the same table.

- BAdI class: [ZCL_IM_MM_PO_SPLIT_VAL.abap](ZCL_IM_MM_PO_SPLIT_VAL.abap)
- Mass update report: [ZPTP_PO_SPLIT_VAL_UPDATE.abap](ZPTP_PO_SPLIT_VAL_UPDATE.abap)
- Document alignment report (PO items, open inbound deliveries, batches):
  [ZPTP_VALTYPE_DOCSALIGN.abap](ZPTP_VALTYPE_DOCSALIGN.abap)
- Functional and technical specification, setup, tests and transport:
  [SPECIFICATION.md](SPECIFICATION.md)

Report `ZPTP_PROD_BATCH_VALTYPE` (valuation type in the batch master of open
production orders) has been moved to WRICEF project
HBM-Wricefs Badi Workorders_Goodsmvt. It still uses table `ZPTP_301_VALTYPE` and
messages 111–116 of class `ZPTP_SPLIT_VAL`.
