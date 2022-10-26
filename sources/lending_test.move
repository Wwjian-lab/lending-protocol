module lending_protocol::test {

    use lending_protocol::lending_protocol;

    use std::signer::address_of;
    use std::string;
    use std::account;
    // use std::vector;

    use aptos_framework::coin;
    use aptos_framework::timestamp;

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

    const MINT_AMOUNT: u64 = 100000;

    // ========= test =========
    #[test(admin=@lending_protocol)]
    public entry fun test_init(admin: &signer) {
        account::create_account_for_test(address_of(admin));
        lending_protocol::init(admin);
    }

    #[test(admin=@lending_protocol, userA=@0x1000000, userB=@0x200000, aptss_framework_admin=@0x1)]
    public entry fun test_add_pool(admin: &signer, userA: &signer, userB: &signer, aptss_framework_admin: &signer){
        // let intrest_rate = 1;
        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(userA));
        account::create_account_for_test(address_of(userB));
        lending_protocol::init(admin);
        init_coin_and_fund_user(admin, userA, userB);
        timestamp::set_time_has_started_for_testing(aptss_framework_admin);
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
        
        // 2.TODO: register
        coin::register<AptTest>(userA);
        coin::register<EthTest>(userA);
        coin::register<BtcTest>(userA);

        coin::register<AptTest>(userB);
        coin::register<EthTest>(userB);
        coin::register<BtcTest>(userB);
        // 3. mint
        let apt_minted_vault = coin::mint<AptTest>(MINT_AMOUNT, &apt_mint);
        let eth_minted_vault = coin::mint<EthTest>(MINT_AMOUNT, &eth_mint);
        let btc_minted_vault = coin::mint<BtcTest>(MINT_AMOUNT, &btc_mint);

        let apt_mintedA = coin::extract<AptTest>(&mut apt_minted_vault, MINT_AMOUNT/4);
        let eth_mintedA = coin::extract<EthTest>(&mut eth_minted_vault, MINT_AMOUNT/4);
        let btc_mintedA = coin::extract<BtcTest>(&mut btc_minted_vault, MINT_AMOUNT/4);

        let apt_mintedB = coin::extract<AptTest>(&mut apt_minted_vault, MINT_AMOUNT/4);
        let eth_mintedB = coin::extract<EthTest>(&mut eth_minted_vault, MINT_AMOUNT/4);
        let btc_mintedB = coin::extract<BtcTest>(&mut btc_minted_vault, MINT_AMOUNT/4);
        
        // 4. deposit to destination account
        coin::deposit(address_of(userA), apt_mintedA);
        coin::deposit(address_of(userA), eth_mintedA);
        coin::deposit(address_of(userA), btc_mintedA);

        coin::deposit(address_of(userA), apt_mintedB);
        coin::deposit(address_of(userA), eth_mintedB);
        coin::deposit(address_of(userA), btc_mintedB);

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
}