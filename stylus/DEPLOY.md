# Contract Deployment Guide


- settlement: 0x228e6a6aeb0c84c3844ee474c9582f105bbc66a6
- schema: 0x4615b03ccaf5e834490a94211e129e6ee8ec6604
- datasource: 0xb728fc5943398902d0d1385eb84251ded3f93a23

1. Deploy the settlement registry

From /stylus/SettlementRegistry

``` sh
cargo stylus deploy --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
```

`0x228e6a6aeb0c84c3844ee474c9582f105bbc66a6`

2. Deploy the schema registry

From /stylus/SchemaRegistry

``` sh
cargo stylus deploy --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6
```

Store the contract address (used below), e.g. 
`0x4615b03ccaf5e834490a94211e129e6ee8ec6604`

cast call \
  0xd925f5a5a01843a1e8a10db8127cc98f7890c58c \
  "getAdmin()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc


3. Deploy the datasource registry

From /stylus/DatasourceRegistry

the args are schema reg + settlement reg

``` sh
cargo stylus deploy --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
  --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x4615b03ccaf5e834490a94211e129e6ee8ec6604 0x228e6a6aeb0c84c3844ee474c9582f105bbc66a6
```

`0xb728fc5943398902d0d1385eb84251ded3f93a23`

4. set datasource registry in schema registry

``` sh
cast send \
  0x4615b03ccaf5e834490a94211e129e6ee8ec6604 \
  "setDataSourceRegistry(address)" \
  0xb728fc5943398902d0d1385eb84251ded3f93a23 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb
```

verify 

cast call \
  0xd925f5a5a01843a1e8a10db8127cc98f7890c58c \
  "getDataSourceRegistry()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc


5. Configure the datasource registry in the settlement registry

``` sh
cast send \
  0x228e6a6aeb0c84c3844ee474c9582f105bbc66a6 \
  "setRegistry(address,bool)" \
  0xb728fc5943398902d0d1385eb84251ded3f93a23 true \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb
```

cast call \
  0x5dd630d325690eb0821cc18e54c9639e8068e950 \
  "getAdmin()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc