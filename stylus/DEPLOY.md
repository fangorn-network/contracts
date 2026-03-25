# Contract Deployment Guide


1. Deploy the schema registry

From /stylus/SchemaRegistry

``` sh
cargo stylus deploy --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1
```

Store the contract address (used below), e.g. `0xef6754c29cfd0c8937a080695899f2a9a23c7c70`

2. Deploy the datasource registry

From /stylus/DatasourceRegistry

``` sh
cargo stylus deploy --private-key 0xde0e6c1c331fcd8692463d6ffcf20f9f2e1847264f7a3f578cf54f62f05196cb  \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
  --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x0a5df1e39f880e002af9e9dbf75ef9367a39f6c0
```

0xddd338e6a200012642a103c6631ea92eea94cabe


3. Deploy the settlement registry

From /stylus/SettlementRegistry

``` sh
cargo stylus deploy --private-key 0xYourKey \
 --endpoint https://sepolia-rollup.arbitrum.io/rpc \
 --max-fee-per-gas-gwei 0.1 \
 --constructor-args 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
```