# Datasource Registry

The datasource registry allows accounts to publish Merkle roots of 'datasets', where each data set is a Merkle Mountain Range, the root is computed with the poseiden2 hash, and updates require a proof.

Users publish aganist a global MMR, with updates requiring proof that the old state existing, and the new state is valid and owned by the correct origin.

This registry makes cross-contract calls to both the SchemaRegistry (to check existence, validity, and alert that data is published against a specific schema). Each leaf of an individual MMR could be mapped to a unique schema, with a unique access condition (starting with price). 


cargo stylus cache bid ecafc21ca3ec41c020287fb8c2126b1a9af9d220 0