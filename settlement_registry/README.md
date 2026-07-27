# Settlement Registry

USDC="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
SEMAPHORE="0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D"

``` sh
cargo stylus deploy \
    --private-key <private_key> \
    --endpoint https://sepolia-rollup.arbitrum.io/rpc \
    --max-fee-per-gas-gwei 0.1 \
    --constructor-args 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D
```
