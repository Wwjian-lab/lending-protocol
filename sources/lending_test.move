module lending_protocol::test {

    use lending_protocol::lending_protocol;

    use std::signer::address_of;
    use std::string;
    // use std::vector;
    use std::account as sys_account;

    use aptos_framework::coin;

    struct FakeMoney {}
    struct AptTest {}
    struct EthTest {}

    struct FakeMoneyCapabilities has key {
        burn_cap: coin::BurnCapability<FakeMoney>,
        freeze_cap: coin::FreezeCapability<FakeMoney>,
        mint_cap: coin::MintCapability<FakeMoney>,
    }

    const MINT_AMOUNT: u64 = 100000;

    // ========= test =========
    #[test(admin=@lending_protocol)]
    public entry fun test_init(admin: &signer) {
        sys_account::create_account_for_test(address_of(admin));
        lending_protocol::init(admin);
    }

    #[test(admin=@lending_protocol, userA=@0x10, intrest_rate=@1)]
    public entry fun test_add_pool(admin: &signer, userA: &signer, intrest_rate: u64) {
        // coin::create_fake_money(admin, userA, MINT_AMOUNT);
        sys_account::create_account_for_test(address_of(admin));
        sys_account::create_account_for_test(address_of(userA));
        create_fake_money_to(admin, userA, MINT_AMOUNT);
        lending_protocol::add_pool<FakeMoney>(admin, intrest_rate);
    }

    // ========= test_only =========
    #[test_only]
    fun initialize_and_register_token(
        account: &signer
    ): (coin::BurnCapability<FakeMoney>, coin::FreezeCapability<FakeMoney>, coin::MintCapability<FakeMoney>)
    {
        let name = string::utf8(b"eth");
        let symbol = string::utf8(b"ETH");
        let decimals = 8u8;
        let (eth_burn, eth_freeze, eth_mint) = coin::initialize<FakeMoney>(account, copy name, symbol, decimals, false);
        coin::register<FakeMoney>(account);
        (eth_burn, eth_freeze, eth_mint)
    }

    #[test_only]
    fun create_fake_money_to(
        source: &signer,
        destination: &signer,
        amount: u64
    ) {
        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_token(source);
        coin::register<FakeMoney>(destination);
        let coins_minted = coin::mint<FakeMoney>(amount, &mint_cap);
        coin::deposit(address_of(source), coins_minted);
        move_to(source, FakeMoneyCapabilities{burn_cap, freeze_cap, mint_cap});
    }
}