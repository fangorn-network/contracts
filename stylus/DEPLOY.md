# Contract Deployment Guide

- settlement: 0x1d21545f536a2f026348477960ca59f9f1d7fabd
- schema: 0x267084865813550d9d97d3842c4a2d33a872908f
- datasource: 0xe8a5906825680a5816a7f28f2a0fa2d9ceec3755

1. Deploy the settlement registry

From /stylus/SettlementRegistry

``` sh
cargo stylus deploy --private-key <Private Key> \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
```

`0x1d21545f536a2f026348477960ca59f9f1d7fabd`

2. Deploy the schema registry

From /stylus/SchemaRegistry

``` sh
cargo stylus deploy --private-key <Private Key>  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6
```

Store the contract address (used below), e.g. 
`0x267084865813550d9d97d3842c4a2d33a872908f`

cast call \
  0xd925f5a5a01843a1e8a10db8127cc98f7890c58c \
  "getAdmin()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc


3. Deploy the datasource registry

From /stylus/DatasourceRegistry

the args are schema reg + settlement reg

``` sh
cargo stylus deploy --private-key <Private Key>  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
  --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x267084865813550d9d97d3842c4a2d33a872908f 0x1d21545f536a2f026348477960ca59f9f1d7fabd
```

`0xe8a5906825680a5816a7f28f2a0fa2d9ceec3755`

4. set datasource registry in schema registry

``` sh
cast send \
  0x267084865813550d9d97d3842c4a2d33a872908f \
  "setDataSourceRegistry(address)" \
  0xe8a5906825680a5816a7f28f2a0fa2d9ceec3755 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key <Private Key>
```

verify 

cast call \
  0xd925f5a5a01843a1e8a10db8127cc98f7890c58c \
  "getDataSourceRegistry()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc


5. Configure the datasource registry in the settlement registry

``` sh
cast send \
  0x1d21545f536a2f026348477960ca59f9f1d7fabd \
  "setRegistry(address,bool)" \
  0xe8a5906825680a5816a7f28f2a0fa2d9ceec3755 true \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key <Private Key>
```

cast call \
  0x5dd630d325690eb0821cc18e54c9639e8068e950 \
  "getAdmin()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc