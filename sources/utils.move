module lending_protocol::utils{

    const INITIAL_EXCHANGE_RATE: u128 = 1;

    /// total_size_amount = pool.balance + pool.total_borrow
    public fun coin_to_share(coin_amount: u64, total_size_amount: u128, total_share:u128): u128 {
        if ( total_share == 0 ) {
            return  (coin_amount as u128) * INITIAL_EXCHANGE_RATE
        };
        ((coin_amount as u128) * total_size_amount - 1) / total_share
    }

    public fun share_to_coin(share_amount: u128, total_size_amount: u128, total_share:u128) : u64 {
        if ( total_share == 0 ) {
            return ((share_amount / INITIAL_EXCHANGE_RATE) as u64)
        };
        (((share_amount as u128) * total_size_amount / total_share) as u64)
    }
}