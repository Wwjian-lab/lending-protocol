module lending_protocol::lending_protocol {

    use std::vector;
    use std::signer;
    use std::event;
    use std::account as sys_account;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

    use aptos_std::type_info;
    use aptos_std::simple_map;
    // use aptos_std::debug;

    use lending_protocol::oracle;

    // errors
    const ERR_NOT_ADMIN: u64 = 408;
    const ERR_LENDINGPOOL_ALREADY_EXIST: u64 = 409;
    const ERR_INVALID_COIN: u64 = 410;
    const ERR_LENDINGPROTOCOL_NOT_EXIST: u64 = 411;
    const ERR_INCORRECT_COINTYPE: u64 = 412;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 413;
    const ERR_USER_POSITION_NOT_EXIST: u64 = 414;
    const ERR_POOL_NOT_ACTIVE: u64 = 415;
    const ERR_LACK_OF_LIQUIDITY: u64 = 416;
    const ERR_INSUFFICIENT_CASH: u64 = 417;

    // const 
    const INDEX_ONE: u128 = 100000000000000000;
    const INITIAL_EXCHANGE_RATE: u128 = 1;
    // 1e18
    const CALC_SCALE: u128 = 1000000000000000000;
    // 1e10
    const INTEREST_PRECISION: u128 = 10000000000;
    // 1e18
    const EXCHAGE_PRECISION: u128 = 1;


    struct LendingProtocol has key, store {
        pools: vector<LendingPool>,
        users: vector<address>,
        pool_index: simple_map::SimpleMap<type_info::TypeInfo, u64>,
    }

    struct UserPositions has key, store {
        deposits: simple_map::SimpleMap<u64, DepositPosition>,
        borrows: simple_map::SimpleMap<u64, BorrowPosition>,
    }

    // valut TODO: Unable to query balance 
    struct CoinStore<phantom CoinType> has key, store {
        coin: Coin<CoinType>,
    }

    struct FeeToEvent has drop, store { 
        fee_to: address, 
        amount: u64
    }

    // pool info
    struct LendingPool has key, store {
        total_borrow: u128,
        coin_type: type_info::TypeInfo,
        borrow_index: u128,
        totoal_supply_share: u128,
        interest_per_second: u64,
        last_accrued: u64,
        is_active: bool,
        fee_to: address,
        fee_to_events: event::EventHandle<FeeToEvent>,
        coin_price: u64,
        coin_balance: u64,
    }

    struct DepositPosition has copy, drop, store {
        as_collateral: bool,
        pool_share: u128,
        deposit_amount: u64,
    }

    struct BorrowPosition has copy, drop, store {
        borrow_amount: u64,
        interest_facotor: u128,
    }

    // ========= public =========
    public entry fun init(account: &signer) {
        assert!(signer::address_of(account) == @lending_protocol, ERR_NOT_ADMIN);

        move_to<LendingProtocol>(account, LendingProtocol{
            users: vector::empty<address>(),
            pools: vector::empty<LendingPool>(),
            pool_index: simple_map::create<type_info::TypeInfo, u64>(),
        })
    }

    public entry fun add_pool<CoinType>(account: &signer, interest_rate: u64) acquires LendingProtocol {

        assert!(signer::address_of(account) == @lending_protocol, ERR_NOT_ADMIN);

        // make sure the protocol has been initialized
        assert!(exists<LendingProtocol>(signer::address_of(account)),ERR_LENDINGPROTOCOL_NOT_EXIST);

        assert!(!exists<LendingPool>(signer::address_of(account)), ERR_LENDINGPOOL_ALREADY_EXIST);

        assert!(coin::is_coin_initialized<CoinType>(), ERR_INVALID_COIN);

        // regist address
        coin::register<CoinType>(account);

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        let now = timestamp::now_microseconds();

        let pool_id = vector::length(&protocol.pools);
        let coint_type_tmp = type_info::type_of<CoinType>();
        let pool = LendingPool {
            total_borrow: 0,
            coin_type: coint_type_tmp,
            borrow_index: INDEX_ONE,
            totoal_supply_share: 0,
            is_active: true,
            fee_to: signer::address_of(account),
            last_accrued: now,
            interest_per_second: interest_rate,
            fee_to_events: sys_account::new_event_handle<FeeToEvent>(account),
            coin_price: 0,
            coin_balance: 0
        };

        move_to<CoinStore<CoinType>>(account, CoinStore<CoinType>{coin: coin::zero<CoinType>()});

        vector::push_back(&mut protocol.pools, pool);
        simple_map::add<type_info::TypeInfo, u64>(&mut protocol.pool_index, coint_type_tmp, pool_id);
    }

    public entry fun deposit<CoinType>(user: &signer, amount: u64)
        acquires
        LendingProtocol,
        UserPositions,
        CoinStore
    {
        // make sure the protocol has been initialized
        assert!(exists<LendingProtocol>(@lending_protocol), ERR_LENDINGPROTOCOL_NOT_EXIST);

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        
        // make sure the user have the resource, otherwise create it for the user
        ensure_user_exists(user, protocol);

        // get pid && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!( pool.is_active , ERR_POOL_NOT_ACTIVE);

        // accrue interest
        accrue_interest(pool);

        assert_coin_type<CoinType>(pool.coin_type);

        // get user positions
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));

        // totoal coin in valut
        let cash = borrow_global_mut<CoinStore<CoinType>>(@lending_protocol);
        // get user coin
        let coin = coin::withdraw<CoinType>(user, amount);
        // make sure amont
        let amount = coin::value(&coin);

        if (!simple_map::contains_key<u64, DepositPosition>(&user_positions.deposits, &pid)) {
            simple_map::add<u64, DepositPosition>(&mut user_positions.deposits, pid, DepositPosition{deposit_amount: 0, as_collateral: true, pool_share: 0});
        };

        let user_deposit = simple_map::borrow_mut(&mut user_positions.deposits, &pid);

        let actual_share_get = coin_to_share<CoinType>(pool, amount);
        
        // book
        user_deposit.pool_share =  user_deposit.pool_share + actual_share_get;
        pool.totoal_supply_share = pool.totoal_supply_share + actual_share_get;

        // transfer coins
        coin::merge(&mut cash.coin, coin);
        pool.coin_balance = pool.coin_balance + amount;
    }

    public entry fun withdraw<CoinType>(user: &signer, amount: u64) 
        acquires 
        LendingProtocol,
        UserPositions,
        CoinStore
    {
        // make sure the protocol has been initialized
        assert_user_pool(signer::address_of(user));
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        // get pool id && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!( pool.is_active, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // accrue interest
        accrue_interest(pool);

        // withdraw check
        assert!( withdraw_allowd(amount), ERR_INSUFFICIENT_COLLATERAL);

        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<CoinStore<CoinType>>(@lending_protocol);

        let user_deposit = simple_map::borrow_mut(&mut user_positions.deposits, &pid);

        let share_to_withdraw = coin_to_share<CoinType>(pool, amount);

        let amount_stored = share_to_coin<CoinType>(pool, user_deposit.pool_share);

        // whether to withdraw all
        let (actual_withdraw_amount, actual_withdraw_share) = if ( (amount as u128) >= (amount_stored as u128)) {
            ((amount_stored as u64), user_deposit.pool_share)
        } else {
            (amount, share_to_withdraw)
        };

        let coin = coin::extract(&mut cash.coin, actual_withdraw_amount);

        // book
        user_deposit.pool_share = user_deposit.pool_share - actual_withdraw_share;
        pool.totoal_supply_share =  pool.totoal_supply_share - actual_withdraw_share;

        // transfer coin
        ensure_account_registered<CoinType>(user);
        coin::deposit(signer::address_of(user), coin);
        pool.coin_balance = pool.coin_balance - actual_withdraw_amount;

        assert!( get_hypothetical_account_liquidity_internal(protocol, user_positions), ERR_LACK_OF_LIQUIDITY);
    }

    public entry fun borrow<CoinType>(user: &signer, amount: u64)
        acquires
        LendingProtocol,
        UserPositions,
        CoinStore
    {
        // make sure the protocol has been initialized && user position exist
        assert_user_pool(signer::address_of(user));

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        // get pid && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!( pool.is_active, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // accrue interest
        accrue_interest(pool);

        // borrow check
        assert!( borrow_allowed(amount), ERR_INSUFFICIENT_COLLATERAL);

        // get global params
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<CoinStore<CoinType>>(@lending_protocol);
        
        // get coin
        let coin = coin::extract(&mut cash.coin, amount);

        // maker sure user pool exist
        if ( !simple_map::contains_key<u64, BorrowPosition>(&user_positions.borrows, &pid) ){
            simple_map::add<u64, BorrowPosition>(&mut user_positions.borrows, pid, BorrowPosition{ borrow_amount: 0 , interest_facotor: 0});
        };
        let borrow_position = simple_map::borrow_mut(&mut user_positions.borrows, &pid);

        // update new index & update the ledgerbook
        let borrow_balance_stored = get_borrow_balance_stored(pool, borrow_position);
        let account_borrow_new = borrow_balance_stored + (amount as u128);
        let borrow_total_new = (pool.total_borrow as u128) + (amount as u128);

        pool.total_borrow = borrow_total_new;
        borrow_position.borrow_amount = (account_borrow_new as u64);
        borrow_position.interest_facotor = pool.borrow_index;

        // transfer coin
        ensure_account_registered<CoinType>(user);
        coin::deposit(signer::address_of(user), coin);
        pool.coin_balance = pool.coin_balance - amount;

        assert!( get_hypothetical_account_liquidity_internal(protocol, user_positions), ERR_LACK_OF_LIQUIDITY);
    }

    public entry fun repay<CoinType>(user: &signer, amount: u64)
        acquires
        LendingProtocol,
        UserPositions,
        CoinStore
    {
        // make sure the protocol has been initialized && user position exist
        assert_user_pool(signer::address_of(user));

        // get resources
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);

        // accrue borrow interest
        accrue_interest(pool);

        // do repay internal
        do_repay_internal<CoinType>(user, amount, user_positions, pid, pool);
    }

    fun do_repay_internal<CoinType>(user: &signer, amount: u64, user_positions: &mut UserPositions, pid: u64, pool: &mut LendingPool)
        acquires
        CoinStore
    {
        assert!( pool.is_active, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // record
        let cash = borrow_global_mut<CoinStore<CoinType>>(@lending_protocol);
        let borrow_position = simple_map::borrow_mut(&mut user_positions.borrows, &pid);

        let borrow_balance_stored = get_borrow_balance_stored(pool, borrow_position);

        // repay max amount
        if ( borrow_balance_stored <= (amount as u128) ) {
            amount = (borrow_balance_stored as u64);
        };

        
        let coin = coin::withdraw<CoinType>(user, amount);

        // update
        let account_borrow_new = borrow_balance_stored - (amount as u128);
        let totoal_borrow_new = (pool.total_borrow as u128) - (amount as u128);

        pool.total_borrow = totoal_borrow_new;
        borrow_position.borrow_amount = (account_borrow_new as u64) ;
        borrow_position.interest_facotor = pool.borrow_index;

        // transfer coin
        coin::merge<CoinType>(&mut cash.coin, coin);
        pool.coin_balance = pool.coin_balance - amount;
    }

    public entry fun set_open_collateral<CoinType>(user: &signer, if_open: bool) acquires LendingProtocol, UserPositions{
        assert!(exists<LendingProtocol>(@lending_protocol), ERR_LENDINGPROTOCOL_NOT_EXIST);
        assert!(exists<UserPositions>(signer::address_of(user)), ERR_USER_POSITION_NOT_EXIST);
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let pid = get_pool_id<CoinType>(protocol);
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let deposit_position = simple_map::borrow_mut(&mut user_positions.deposits, &pid);
        deposit_position.as_collateral = if_open;
        assert!( get_hypothetical_account_liquidity_internal(protocol, user_positions), ERR_LACK_OF_LIQUIDITY);
    }

    public entry fun deactivate_pool<CoinType>() acquires LendingProtocol {
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        pool.is_active = false;
    }

    public entry fun get_reserve<CoinType>(admin: &signer) acquires CoinStore {
        assert!(signer::address_of(admin) == @lending_protocol, ERR_NOT_ADMIN);
        let cash = borrow_global_mut<CoinStore<CoinType>>(@lending_protocol);
        let coin = coin::extract_all(&mut cash.coin);
        coin::deposit<CoinType>(signer::address_of(admin), coin);
    }

    fun coin_to_share<CoinType>(pool: &LendingPool,coin_amount: u64):u128 {
        let total_size = total_size<CoinType>(pool);
        lending_protocol::utils::coin_to_share(coin_amount, total_size, pool.totoal_supply_share)
    }

    fun share_to_coin<CoinType>(pool: &LendingPool,share_amount: u128):u64 {
        let total_size = total_size<CoinType>(pool);
        lending_protocol::utils::share_to_coin(share_amount, total_size, pool.totoal_supply_share)
    }

    fun total_size<CoinType>(pool: &LendingPool): u128  {
        pool.total_borrow + (pool.coin_balance as u128)
    }

    // ========= internal =========
    fun accrue_interest(pool: &mut LendingPool) {
        let now_sec = timestamp::now_seconds();
        let delta_time = now_sec - pool.last_accrued;
        if ( delta_time == 0 ) {
            return 
        };
        let interest_facotor = (delta_time as u128) * ((pool.interest_per_second as u128) * CALC_SCALE / INTEREST_PRECISION);
        let interest_accumulated = pool.total_borrow * interest_facotor / CALC_SCALE + 1;
        let total_borrow_new = pool.total_borrow + interest_accumulated;
        let borrow_index_new = ( interest_facotor as u128 ) / CALC_SCALE * INTEREST_PRECISION  * pool.borrow_index + pool.borrow_index;
        pool.borrow_index = borrow_index_new;
        pool.last_accrued = now_sec;
        pool.total_borrow = total_borrow_new;
    }

    fun get_borrow_balance_stored(pool: &LendingPool, borrow_position: &BorrowPosition): u128 {
        if ( borrow_position.borrow_amount == 0 ) {
            return 0
        };
        (borrow_position.borrow_amount as u128) * pool.borrow_index / INTEREST_PRECISION / borrow_position.interest_facotor
    }

    fun exchange_share_rate_stored<CoinType>(pool: &LendingPool, coinStore: &CoinStore<CoinType>): u128
    {
        if ( pool.totoal_supply_share == 0 ) {
            return INITIAL_EXCHANGE_RATE
        };
        let balance = coin::value<CoinType>(&coinStore.coin);
        ((balance as u128) + pool.total_borrow) * EXCHAGE_PRECISION / pool.totoal_supply_share
    }

    fun withdraw_allowd(withdraw_amont: u64): bool {
        // currently unused
        withdraw_amont;
        true
    }

    fun borrow_allowed(borrow_amount: u64): bool{
        // currently unused
        borrow_amount;
        true
    }

    fun get_hypothetical_account_liquidity_internal(
        lending_protocol: &mut LendingProtocol,
        user_position: &mut UserPositions,
    ): bool {
        let pool_number = vector::length<LendingPool>(&lending_protocol.pools);
        // let length = simple_map::length<u64, DepositPosition>(&user_position.deposits);
        let idx = 0u64;
        let total_colleteral_USD_value: u64 = 0;
        let total_borrow_USD_value: u64 = 0;
        while ( idx < pool_number ) {

            // get lenging pool
            let pool = vector::borrow<LendingPool>(&lending_protocol.pools, idx);

            let coin_type = pool.coin_type;

            // if user have deposited this coin
            if ( simple_map::contains_key<u64, DepositPosition>(&user_position.deposits, &idx) ){
                let user_deposit_postision = simple_map::borrow<u64, DepositPosition>(&user_position.deposits, &idx);
                let total_pool_size = (pool.coin_balance as u128) + pool.total_borrow;

                let user_deposit_amount = lending_protocol::utils::share_to_coin(user_deposit_postision.pool_share, total_pool_size, pool.totoal_supply_share);

                if ( user_deposit_postision.as_collateral ){
                    total_colleteral_USD_value = total_colleteral_USD_value + user_deposit_amount * oracle::get_usd_price(coin_type);
                } else {
                    continue
                };
            };

            // if user have borrowed this coin
            if ( simple_map::contains_key<u64, BorrowPosition>(&user_position.borrows, &idx) ){
                let user_borrow_position = simple_map::borrow<u64, BorrowPosition>(&user_position.borrows, &idx);
                total_borrow_USD_value = total_borrow_USD_value + user_borrow_position.borrow_amount * oracle::get_usd_price(coin_type);
            };

            idx = idx+1;
        };

        // colleteral factor = 80%
        return total_colleteral_USD_value * 80 >= total_borrow_USD_value * 100
    }

    fun ensure_account_registered<CoinType>(user: &signer) {
        if (!coin::is_account_registered<CoinType>(signer::address_of(user))) {
            coin::register<CoinType>(user);
        }
    }

    fun ensure_user_exists(user: &signer, protocol: &mut LendingProtocol) {
        if (!exists<UserPositions>(signer::address_of(user))) {
            move_to(user, UserPositions{
                deposits: simple_map::create<u64, DepositPosition>(),
                borrows: simple_map::create<u64, BorrowPosition>(),
            });
            vector::push_back(&mut protocol.users, signer::address_of(user));
        }
    }

    fun assert_user_pool(user: address) {
        assert!(exists<LendingProtocol>(@lending_protocol), ERR_LENDINGPROTOCOL_NOT_EXIST);
        assert!(exists<UserPositions>(user), ERR_USER_POSITION_NOT_EXIST);
    }


    fun get_pool_id<CoinType>(protocol: &LendingProtocol):u64 {
        let coin_type = type_info::type_of<CoinType>();
        *simple_map::borrow<type_info::TypeInfo, u64>(&protocol.pool_index, &coin_type)
    }

    fun coin_address<CoinType>(): address {
        let type_info = type_info::type_of<CoinType>();
        type_info::account_address(&type_info)
    }

    fun assert_coin_type<CoinType>(type:type_info::TypeInfo) {
        assert!(type == type_info::type_of<CoinType>(), ERR_INCORRECT_COINTYPE);
    }
}