module lending_protocol::test {

    use lending_protocol::lending_protocol;

    use std::signer::address_of;
    use std::string;
    use std::account;
    // use std::vector;

    use aptos_framework::coin;
    use aptos_framework::timestamp;

    use aptos_std::debug;
    // use aptos_std::type_info;

    struct AptTest {}
    struct EthTest {}
    struct BtcTest {}

    struct CoinsVault has key {
        apt: coin::Coin<AptTest>,
        eth: coin::Coin<EthTest>,
        btc: coin::Coin<BtcTest>,

        apt_burn: coin::BurnCapability<AptTest>,
        apt_freeze: coin::FreezeCapability<AptTest>,
        apt_mint: coin::MintCapability<AptTest>,

        eth_burn: coin::BurnCapability<EthTest>,
        eth_freeze: coin::FreezeCapability<EthTest>,
        eth_mint: coin::MintCapability<EthTest>,

        btc_burn: coin::BurnCapability<BtcTest>,
        btc_freeze: coin::FreezeCapability<BtcTest>,
        btc_mint: coin::MintCapability<BtcTest>,
    }

    const TOTAL_VAULT: u64 = 1000000000;
    const USER_INIT_AMOUNT: u64 = 5000;

    const ERR_TEST_ERR: u64 = 4444;

    // ========= test =========
    #[test(admin=@lending_protocol)]
    public entry fun test_init(admin: &signer) {
        account::create_account_for_test(address_of(admin));
        lending_protocol::init(admin);
    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptos_framework_admin=@0x1)]
    public entry fun test_add_pool(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){
        before_user_operate(admin, userA, userB, aptos_framework_admin);
    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptos_framework_admin=@0x1)]
    public entry fun test_deposit(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){
        // init
        before_user_operate(admin, userA, userB, aptos_framework_admin);
        
        // test deposit
        let deposit_amount = 200;
        lending_protocol::deposit<AptTest>(userA, deposit_amount);
        lending_protocol::deposit<AptTest>(userA, deposit_amount);

        // assert balance
        // debug::print<u64>(&coin::balance<AptTest>(address_of(userA)));
        assert!( coin::balance<AptTest>(address_of(userA)) == USER_INIT_AMOUNT - 2 * deposit_amount, ERR_TEST_ERR );
    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptos_framework_admin=@0x1)]
    public entry fun test_withdraw(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){
        // init
        before_user_operate(admin, userA, userB, aptos_framework_admin);

        // withdraw half
        let deposit_amount = 400;
        lending_protocol::deposit<AptTest>(userA, deposit_amount);
        let withdraw_amount = 200;
        lending_protocol::withdraw<AptTest>(userA, withdraw_amount);     

        // widraw all
        let deposit_amount = 400;
        lending_protocol::deposit<AptTest>(userA, deposit_amount);
        let withdraw_amount = 400;
        lending_protocol::withdraw<AptTest>(userA, withdraw_amount);

    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptos_framework_admin=@0x1)]
    public entry fun test_borrow(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){
        // init
        before_user_operate(admin, userA, userB, aptos_framework_admin);
        
        let deposit_amount = 400;
        lending_protocol::deposit<AptTest>(userA, deposit_amount);
        let borrow_amount = 100;
        lending_protocol::borrow<AptTest>(userA, borrow_amount);

    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptos_framework_admin=@0x1)]
    public entry fun test_repay(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){
        
        before_user_operate(admin, userA, userB, aptos_framework_admin);
        
        let deposit_amount = 400;
        lending_protocol::deposit<AptTest>(userA, deposit_amount);
        let borrow_amount = 100;
        lending_protocol::borrow<AptTest>(userA, borrow_amount);

        // overpayment
        lending_protocol::repay<AptTest>(userA, borrow_amount * borrow_amount);
    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptos_framework_admin=@0x1)]
    public entry fun test_borrow_rate(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){

        before_user_operate(admin, userA, userB, aptos_framework_admin);

        let deposit_amount = 500;
        lending_protocol::deposit<AptTest>(userA, deposit_amount);


        let borrow_amount = 1;
        lending_protocol::borrow<AptTest>(userA, borrow_amount);

        timestamp::fast_forward_seconds(4); // TODO:

        let balance_before = coin::balance<AptTest>(address_of(userA));
        let expected_repay_amount: u64 =  1 * 1 * 5 ; // TODO:
        
        lending_protocol::repay<AptTest>(userA, 100);
        let balance_after = coin::balance<AptTest>(address_of(userA));

        debug::print<u64>(&balance_before);
        debug::print<u64>(&balance_after);
        assert!(expected_repay_amount == balance_before - balance_after, ERR_TEST_ERR);
    }

    // ========= test_only =========
    #[test_only]
    fun init_coin_and_fund_user(admin: &signer, userA: &signer, userB: &signer) {
        let decimals = 18u8;
        let name = string::utf8(b"name");
        // 1. initialze
        let (apt_burn, apt_freeze, apt_mint) = coin::initialize<AptTest>(admin, name, name, decimals, false);
        let (eth_burn, eth_freeze, eth_mint) = coin::initialize<EthTest>(admin, name, name, decimals, false);
        let (btc_burn, btc_freeze, btc_mint) = coin::initialize<BtcTest>(admin, name, name, decimals, false);
        
        // 2. register
        coin::register<AptTest>(userA);
        coin::register<EthTest>(userA);
        coin::register<BtcTest>(userA);

        coin::register<AptTest>(userB);
        coin::register<EthTest>(userB);
        coin::register<BtcTest>(userB);
        // 3. mint
        let apt_minted_vault = coin::mint<AptTest>(TOTAL_VAULT, &apt_mint);
        let eth_minted_vault = coin::mint<EthTest>(TOTAL_VAULT, &eth_mint);
        let btc_minted_vault = coin::mint<BtcTest>(TOTAL_VAULT, &btc_mint);

        let apt_mintedA = coin::extract<AptTest>(&mut apt_minted_vault, USER_INIT_AMOUNT);
        let eth_mintedA = coin::extract<EthTest>(&mut eth_minted_vault, USER_INIT_AMOUNT);
        let btc_mintedA = coin::extract<BtcTest>(&mut btc_minted_vault, USER_INIT_AMOUNT);

        let apt_mintedB = coin::extract<AptTest>(&mut apt_minted_vault, USER_INIT_AMOUNT);
        let eth_mintedB = coin::extract<EthTest>(&mut eth_minted_vault, USER_INIT_AMOUNT);
        let btc_mintedB = coin::extract<BtcTest>(&mut btc_minted_vault, USER_INIT_AMOUNT);
        
        // 4. deposit to destination account
        coin::deposit(address_of(userA), apt_mintedA);
        coin::deposit(address_of(userA), eth_mintedA);
        coin::deposit(address_of(userA), btc_mintedA);

        coin::deposit(address_of(userB), apt_mintedB);
        coin::deposit(address_of(userB), eth_mintedB);
        coin::deposit(address_of(userB), btc_mintedB);

        // 5. vault store
        move_to(admin, CoinsVault{
            apt: apt_minted_vault,
            eth: eth_minted_vault,
            btc: btc_minted_vault,

            apt_burn: apt_burn,
            apt_freeze: apt_freeze,
            apt_mint: apt_mint,

            eth_burn: eth_burn,
            eth_freeze: eth_freeze,
            eth_mint: eth_mint,

            btc_burn: btc_burn,
            btc_freeze: btc_freeze,
            btc_mint: btc_mint
        });
    }
    
    // init protocol, pool and fund users
    #[test_only]
    fun before_user_operate(admin: &signer, userA: &signer, userB: &signer, aptos_framework_admin: &signer){
        init_all_accounts(admin, userA, userB);
        lending_protocol::init(admin);
        init_coin_and_fund_user(admin, userA, userB);
        timestamp::set_time_has_started_for_testing(aptos_framework_admin);
        init_all_pool(admin);
    }

    #[test_only]
    fun init_all_pool(admin: &signer) {
        lending_protocol::add_pool<AptTest>(admin, 1);
        lending_protocol::add_pool<EthTest>(admin, 2);
        lending_protocol::add_pool<BtcTest>(admin, 3);
    }
    
    #[test_only]
    fun init_all_accounts(userA: &signer, userB: &signer, userC: &signer) {
        account::create_account_for_test(address_of(userA));
        account::create_account_for_test(address_of(userB));
        account::create_account_for_test(address_of(userC));
    }
}