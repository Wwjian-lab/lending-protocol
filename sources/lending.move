module lending_protocol::lending_protocol {

    use std::vector;
    use std::signer;
    use std::event;
    use std::account as sys_account;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

    use aptos_std::type_info;
    use aptos_std::simple_map;

    // errors
    const ERR_NOT_ADMIN: u64 = 408;
    const ERR_LENDINGPOOL_ALREADY_EXIST: u64 = 409;
    const ERR_INVALID_COIN: u64 = 410;
    const ERR_LENDINGPROTOCOL_NOT_EXIST: u64 = 411;
    const ERR_INCORRECT_COINTYPE: u64 = 412;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 413;
    const ERR_USER_POSITION_NOT_EXIST: u64 = 414;
    const ERR_POOL_NOT_ACTIVE: u64 = 415;

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
        coint_type: type_info::TypeInfo,
        reserve: u64,
        intrest_per_second: u64,
        borrow_rate: u64, // one-time loan interest
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

    public entry fun add_pool<CoinType>(account: &signer, intrest_rate: u64, borrow_rate: u64) acquires LendingProtocol {

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
            coint_type: coint_type_tmp,
            reserve: 0,
            is_active: true,
            fee_to: signer::address_of(account),
            last_accrued: now,
            borrow_rate: borrow_rate,  
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

        assert_coin_type<CoinType>(pool.coint_type);

        // get user positions
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));

        // totoal coin in valut
        let cash = borrow_global_mut<Cash<CoinType>>(signer::address_of(user));
        // get user coin
        let coin = coin::withdraw<CoinType>(user, amount);

        // make sure amont
        let amount = coin::value(&coin);

        coin::merge(&mut cash.value, coin);

        pool.total_deposit = pool.total_deposit + amount;
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

        assert_coin_type<CoinType>(pool.coint_type);

        // withdraw check
        assert!(withdraw_allowd(amount) == true, ERR_INSUFFICIENT_COLLATERAL);

        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<Cash<CoinType>>(signer::address_of(user));

        // record
        let coin = coin::extract(&mut cash.value, amount);
        pool.total_deposit = pool.total_deposit - amount;
        let user_deposit = simple_map::borrow_mut(&mut user_positions.deposits, &pid);
        user_deposit.deposit_amount = user_deposit.deposit_amount - amount;

        // transfer coin
        ensure_account_registered<CoinType>(user);
        coin::deposit(signer::address_of(user), coin);
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

        assert_coin_type<CoinType>(pool.coint_type);

        // borrow check
        assert!(borrow_allowed(amount) == true, ERR_INSUFFICIENT_COLLATERAL);

        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<Cash<CoinType>>(signer::address_of(user));

        // one-time loan interest
        let reserve = amount * pool.borrow_rate / 100;

        // record
        pool.reserve = pool.reserve + reserve;
        let coin = coin::extract(&mut cash.value, amount - reserve);
        let borrow_postion = simple_map::borrow_mut(&mut user_positions.borrows, &pid);

        pool.total_borrow = pool.total_borrow + amount;
        borrow_postion.borrow_amount = borrow_postion.borrow_amount + amount;

        // transfer coin
        ensure_account_registered<CoinType>(user);
        coin::deposit(signer::address_of(user), coin);
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

        assert_coin_type<CoinType>(pool.coint_type);

        // record
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let cash = borrow_global_mut<Cash<CoinType>>(signer::address_of(user));
        let coin = coin::withdraw<CoinType>(user, amount);
        let borrow_postion = simple_map::borrow_mut(&mut user_positions.borrows, &pid);

        pool.total_deposit = pool.total_borrow + amount;
        borrow_postion.borrow_amount = borrow_postion.borrow_amount + amount;

        // transfer coin
        coin::merge(&mut cash.value, coin);
    }

    public entry fun open_collateral<CoinType>(user: &signer) acquires LendingProtocol, UserPositions{
        assert!(exists<LendingProtocol>(@lending_protocol), ERR_LENDINGPROTOCOL_NOT_EXIST);
        assert!(exists<UserPositions>(signer::address_of(user)), ERR_USER_POSITION_NOT_EXIST);
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let pid = get_pool_id<CoinType>(protocol);
        let user_positions = borrow_global_mut<UserPositions>(signer::address_of(user));
        let deposit_position = simple_map::borrow_mut(&mut user_positions.deposits, &pid);
        deposit_position.as_collateral = true;
    }

    public entry fun deactivate_pool<CoinType>() acquires LendingProtocol {
        let protocol = borrow_global_mut<LendingProtocol>(@lending_protocol);
        let pid = get_pool_id<CoinType>(protocol);
        let pool = vector::borrow_mut(&mut protocol.pools, pid);
        pool.is_active = false;
    }

    // ========= internal =========
    fun withdraw_allowd(withdraw_amont: u64): bool {
        withdraw_amont;
        true
    }

    fun borrow_allowed(borrow_amont: u64): bool{
        borrow_amont;
        true
    }

    fun get_hypothetical_account_liquidity_internal() {
        // loop user deposits && is_collateral == true
        // calculate collateral value
        // calculate borrow value
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