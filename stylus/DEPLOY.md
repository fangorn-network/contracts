# Contract Deployment Guide


1. Deploy the schema registry

From /stylus/SchemaRegistry

``` sh
cargo stylus deploy --private-key 0xYourKey \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1
```

Store the contract address (used below), e.g. `0x0a5df1e39f880e002af9e9dbf75ef9367a39f6c0`

2. Deploy the datasource registry

From /stylus/DatasourceRegistry

``` sh
cargo stylus deploy --private-key 0xYourKey \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
  --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x0a5df1e39f880e002af9e9dbf75ef9367a39f6c0
```

0xc94c88d9d7209dd0be903bd5ed582b3ed74540d8


3. Deploy the settlement registry

From /stylus/SettlementRegistry

``` sh
cargo stylus deploy --private-key 0xYourKey \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
```