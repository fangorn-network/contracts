# JS Test for Semaphore Contract

This is a simple test for using the semaphore-based settlement contract.

The test will:

0. Setup
   1. Uses mock values for the stealth address
   2. creates a fresh semaphore identity
   3. creates a new resources (e.g. this is what the schema owner must do) 
    * only needs to be done once
1. Phase 1: Register = pay + join the semaphore group
2. Phase 2: Settle = generate + verify zkp => execute hook logic