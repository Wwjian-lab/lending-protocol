module lending_protocol::oracle {
    use aptos_std::type_info;
    public fun get_usd_price(_type: type_info::TypeInfo): u64 {
        1
    }
}