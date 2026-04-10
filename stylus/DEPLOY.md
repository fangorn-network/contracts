# Contract Deployment Guide

1. Deploy the settlement registry

From /stylus/SettlementRegistry

``` sh
cargo stylus deploy --private-key <PRIVATE KEY> \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
```

`0x720119367630d6e2c6b7c22d584c1ffd3d4271ce`

1. Deploy the schema registry

From /stylus/SchemaRegistry

``` sh
cargo stylus deploy --private-key <PRIVATE KEY>  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x147c24c5Ea2f1EE1ac42AD16820De23bBba45Ef6
```

Store the contract address (used below), e.g. 
`0x115292937ebb6845411385f77e92a86303b212d5`

cast call \
  0x115292937ebb6845411385f77e92a86303b212d5 \
  "getAdmin()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc


1. Deploy the datasource registry

From /stylus/DatasourceRegistry

the args are schema reg + settlement reg

``` sh
cargo stylus deploy --private-key <PRIVATE KEY>  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
  --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x115292937ebb6845411385f77e92a86303b212d5 0x720119367630d6e2c6b7c22d584c1ffd3d4271ce
```

`0x020ee8b38b25845e8595a14435af2c4c453017c8`

4. set datasource registry in schema registry

``` sh
cast send \
  0x115292937ebb6845411385f77e92a86303b212d5 \
  "setDataSourceRegistry(address)" \
  0x020ee8b38b25845e8595a14435af2c4c453017c8 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key <PRIVATE KEY>
```

verify 

cast call \
  0x115292937ebb6845411385f77e92a86303b212d5 \
  "getDataSourceRegistry()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc


5. Configure the datasource registry in the settlement registry

``` sh
cast send \
  0x720119367630d6e2c6b7c22d584c1ffd3d4271ce \
  "setRegistry(address,bool)" \
  0x020ee8b38b25845e8595a14435af2c4c453017c8 true \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key <PRIVATE KEY>
```

cast call \
  0x720119367630d6e2c6b7c22d584c1ffd3d4271ce \
  "getAdmin()(address)" \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc