# ZMM_PO_SPLIT_VAL – Default valuation type on PO items

Implementation of BAdI `ME_PROCESS_PO_CUST` that fills the valuation type
(`BWTAR`) of purchase order items for split-valuated materials, based on the
custom table `ZPTP_PO_VALTYPE`.

Report `ZMM_PO_SPLIT_VAL_UPDATE` sets the valuation type again on open PO items
(no history, no inbound delivery) from the same table, for the fiscal year of
the run date or of a key date. Mainly for background jobs.

- BAdI class: [ZCL_IM_MM_PO_SPLIT_VAL.abap](ZCL_IM_MM_PO_SPLIT_VAL.abap)
- Mass update report: [ZMM_PO_SPLIT_VAL_UPDATE.abap](ZMM_PO_SPLIT_VAL_UPDATE.abap)
- Functional and technical specification, setup, tests and transport:
  [SPECIFICATION.md](SPECIFICATION.md)
