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

    struct LendingProtocol has key, store {
        pools: vector<LendingPool>,
        users: vector<address>,
        pool_index: simple_map::SimpleMap<type_info::TypeInfo, u64>,
    }

    struct UserPositions has key, store {
        deposits: simple_map::SimpleMap<u64, DepositPosition>,
        borrows: simple_map::SimpleMap<u64, BorrowPosition>,
    }

    // valut
    struct Cash<phantom CoinType> has key, store {
        value: Coin<CoinType>,
    }

    struct FeeToEvent has drop, store { 
        fee_to: address, 
        amount: u64
    }

    // pool info
    struct LendingPool has key, store {
        total_deposit: u64,
        total_borrow: u64,
        coin_type: type_info::TypeInfo,
        reserve: u64, // TODO: remove
        intrest_per_second: u64,
        last_accrued: u64,
        is_active: bool,
        fee_to: address,
        fee_to_events: event::EventHandle<FeeToEvent>,
    }

    struct DepositPosition has copy, drop, store {
        as_collateral: bool,
        deposit_amount: u64,
    }

    struct BorrowPosition has copy, drop, store {
        borrow_amount: u64,
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

    public entry fun add_pool<CoinType>(account: &signer, intrest_rate: u64) acquires LendingProtocol {

        assert!(signer::address_of(account) == @lending_protocol, ERR_NOT_ADMIN);

        // make sure the protocol has been initialized
        assert!(exists<LendingProtocol>(signer::address_of(account)),ERR_LENDINGPROTOCOL_NOT_EXIST);

        assert!(!exists<LendingPool>(signer::address_of(account)), ERR_LENDINGPOOL_ALREADY_EXIST);

        assert!(coin::is_coin_initialized<CoinType>(), ERR_INVALID_COIN);

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        let now = timestamp::now_microseconds();

        let pool_id = vector::length(&protocol.pools);
        let coint_type_tmp = type_info::type_of<CoinType>();
        let pool = LendingPool {
            total_deposit: 0,
            total_borrow: 0,
            coin_type: coint_type_tmp,
            reserve: 0,
            is_active: true,
            fee_to: signer::address_of(account),
            last_accrued: now,
            intrest_per_second: intrest_rate,
            fee_to_events: sys_account::new_event_handle<FeeToEvent>(account),
        };

        move_to<Cash<CoinType>>(account, Cash<CoinType>{value: coin::zero<CoinType>(),});

        vector::push_back(&mut protocol.pools, pool);
        simple_map::add<type_info::TypeInfo, u64>(&mut protocol.pool_index, coint_type_tmp, pool_id);
    }

    public entry fun deposit<CoinType>(user: &signer, amount: u64)
        acquires
        LendingProtocol,
        UserPositions,
        Cash
    {
        // make sure the protocol has been initialized
        assert!(exists<LendingProtocol>(@lending_protocol),ERR_LENDINGPROTOCOL_NOT_EXIST);

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        
        // make sure the user have the resource, otherwise create it for the user
        ensure_user_exists(user, protocol);

        // get pid && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!(pool.is_active == true, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // get user positions
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));

        // totoal coin in valut
        let cash = borrow_global_mut<Cash<CoinType>>(@lending_protocol);
        // get user coin
        let coin = coin::withdraw<CoinType>(user, amount);

        // make sure amont
        let amount = coin::value(&coin);

        coin::merge(&mut cash.value, coin);

        pool.total_deposit = pool.total_deposit + amount;

        if (!simple_map::contains_key<u64, DepositPosition>(&user_positions.deposits, &pid)) {
            // TODO: as_collateral
            simple_map::add<u64, DepositPosition>(&mut user_positions.deposits, pid, DepositPosition{deposit_amount:0, as_collateral: true});
        };

        let user_deposit = simple_map::borrow_mut(&mut user_positions.deposits, &pid);
        user_deposit.deposit_amount = user_deposit.deposit_amount + amount;

    }

    public entry fun withdraw<CoinType>(user: &signer, amount: u64) 
        acquires 
        LendingProtocol,
        UserPositions,
        Cash
    {
        // make sure the protocol has been initialized
        assert_user_pool(signer::address_of(user));
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        // get pool id && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!(pool.is_active == true, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // withdraw check
        assert!(withdraw_allowd(amount) == true, ERR_INSUFFICIENT_COLLATERAL);

        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<Cash<CoinType>>(@lending_protocol);

        // TODO: enough cash?
        // record
        let coin = coin::extract(&mut cash.value, amount);
        pool.total_deposit = pool.total_deposit - amount;
        let user_deposit = simple_map::borrow_mut(&mut user_positions.deposits, &pid);
        user_deposit.deposit_amount = user_deposit.deposit_amount - amount;

        // transfer coin
        ensure_account_registered<CoinType>(user);
        coin::deposit(signer::address_of(user), coin);

        assert!(get_hypothetical_account_liquidity_internal(protocol, user_positions) == true, ERR_LACK_OF_LIQUIDITY);
    }

    public entry fun borrow<CoinType>(user: &signer, amount: u64)
        acquires
        LendingProtocol,
        UserPositions,
        Cash
    {
        // make sure the protocol has been initialized && user position exist
        assert_user_pool(signer::address_of(user));

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        // get pid && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!(pool.is_active == true, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // borrow check
        assert!(borrow_allowed(amount) == true, ERR_INSUFFICIENT_COLLATERAL);

        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<Cash<CoinType>>(@lending_protocol);

        // TODO: enough cash
        let coin = coin::extract(&mut cash.value, amount);

        if ( !simple_map::contains_key<u64, BorrowPosition>(&user_positions.borrows, &pid) ){
            simple_map::add<u64, BorrowPosition>(&mut user_positions.borrows, pid, BorrowPosition{ borrow_amount: 0 });
        };

        let borrow_postion = simple_map::borrow_mut(&mut user_positions.borrows, &pid);

        pool.total_borrow = pool.total_borrow + amount;
        borrow_postion.borrow_amount = borrow_postion.borrow_amount + amount;

        // transfer coin
        ensure_account_registered<CoinType>(user);
        coin::deposit(signer::address_of(user), coin);

        assert!(get_hypothetical_account_liquidity_internal(protocol, user_positions) == true, ERR_LACK_OF_LIQUIDITY);
    }

    public entry fun repay<CoinType>(user: &signer, amount: u64)
        acquires
        LendingProtocol,
        UserPositions,
        Cash
    {
        // make sure the protocol has been initialized && user position exist
        assert_user_pool(signer::address_of(user));

        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);

        // get pid && pool
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        assert!(pool.is_active == true, ERR_POOL_NOT_ACTIVE);

        assert_coin_type<CoinType>(pool.coin_type);

        // record
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<Cash<CoinType>>(@lending_protocol);
        let borrow_postion = simple_map::borrow_mut(&mut user_positions.borrows, &pid);

        // repay max amount
        if ( borrow_postion.borrow_amount <= amount ) {
            amount = borrow_postion.borrow_amount;
        };

        let coin = coin::withdraw<CoinType>(user, amount);

        pool.total_deposit = pool.total_borrow + amount;
        borrow_postion.borrow_amount = borrow_postion.borrow_amount + amount;

        // transfer coin
        coin::merge(&mut cash.value, coin);
    }

    public entry fun set_open_collateral<CoinType>(user: &signer, if_open: bool) acquires LendingProtocol, UserPositions{
        assert!(exists<LendingProtocol>(@lending_protocol), ERR_LENDINGPROTOCOL_NOT_EXIST);
        assert!(exists<UserPositions>(signer::address_of(user)), ERR_USER_POSITION_NOT_EXIST);
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let pid = get_pool_id<CoinType>(protocol);
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let deposit_position = simple_map::borrow_mut(&mut user_positions.deposits, &pid);
        deposit_position.as_collateral = if_open;
        assert!(get_hypothetical_account_liquidity_internal(protocol, user_positions) == true, ERR_LACK_OF_LIQUIDITY);
    }

    public entry fun deactivate_pool<CoinType>() acquires LendingProtocol {
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        pool.is_active = false;
    }

    public entry fun get_reserve<CoinType>(admin: &signer) acquires Cash {
        assert!(signer::address_of(admin) == @lending_protocol, ERR_NOT_ADMIN);
        let cash = borrow_global_mut<Cash<CoinType>>(@lending_protocol);
        let coin = coin::extract_all(&mut cash.value);
        coin::deposit<CoinType>(signer::address_of(admin), coin);
    }

    // ========= internal =========
    fun accrue_intrest<PoolType>() {
        
    }

    fun withdraw_allowd(withdraw_amont: u64): bool {
        withdraw_amont;
        true
    }

    fun borrow_allowed(borrow_amont: u64): bool{
        borrow_amont;
        true
    }

    fun get_hypothetical_account_liquidity_internal(
        lending_protocol: &mut LendingProtocol,
        user_position: &mut UserPositions,
    ): bool { // TODO: math
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
                if ( user_deposit_postision.as_collateral ){
                    total_colleteral_USD_value = total_colleteral_USD_value + user_deposit_postision.deposit_amount * oracle::get_usd_price(coin_type);
                } else {
                    // TODO:
                }

            };

            // if user have borrowed this coin
            if ( simple_map::contains_key<u64, BorrowPosition>(&user_position.borrows, &idx) ){
                let user_borrow_position = simple_map::borrow<u64, BorrowPosition>(&user_position.borrows, &idx);
                total_borrow_USD_value = total_borrow_USD_value + user_borrow_position.borrow_amount * oracle::get_usd_price(coin_type);
            };

            idx = idx+1;
        };

        // debug::print<u64>(&total_colleteral_USD_value);
        // debug::print<u64>(&total_borrow_USD_value);

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