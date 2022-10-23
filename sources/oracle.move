module lending_protocol::oracle {
    use aptos_framework::coin;
    public fun get_usd_price<Coin: store>(): u64 {
        1000
    }
}