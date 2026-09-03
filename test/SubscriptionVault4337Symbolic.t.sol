// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault4337} from "../src/SubscriptionVault4337.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @title Propriétés SYMBOLIQUES du coffre v2 — ce qu'un fuzzer ne prouve pas.
///
/// POURQUOI CE FICHIER EXISTE À CÔTÉ DU FUZZER
///     `SubscriptionVault4337Invariant.t.sol` tire des valeurs au hasard et
///     vérifie que rien ne casse. C'est précieux, et ça ne prouve rien : un
///     fuzzer qui n'a pas trouvé de contre-exemple n'a pas démontré qu'il
///     n'en existe pas. Il a échantillonné.
///
///     Halmos, lui, exécute le bytecode sur des valeurs SYMBOLIQUES et
///     demande au solveur : « existe-t-il une entrée qui viole ceci ? ».
///     Une réponse « pas de contre-exemple » couvre alors TOUT le domaine.
///
/// ⚠️  ET C'EST POUR ÇA QUE `unknown` EST ROUGE
///     Halmos rend trois verdicts, pas deux : `passed`, `failed`, et
///     `unknown` — le solveur a renoncé (timeout, boucle non bornée,
///     opération qu'il ne modélise pas). Lire `unknown` comme « pas de
///     contre-exemple trouvé, donc c'est bon » est exactement l'erreur que
///     ce fichier existe pour interdire : ce serait convertir une panne
///     d'instrument en preuve, la faute la plus coûteuse du banc.
///
///     `scripts/halmos_gate.py` le refuse explicitement.
contract SubscriptionVault4337SymbolicTest is Test {
    SubscriptionVault4337 internal vault;
    MockERC20 internal token;

    // Dérivées, jamais écrites à la main : un littéral d'adresse doit porter
    // le bon checksum EIP-55, et les quatre qui étaient ici ne le portaient
    // pas — ce fichier n'a jamais compilé (corrigé le 2026-08-31, à la
    // première exécution réelle de `forge build` dans ce dépôt).
    address internal owner = vm.addr(0xA1);
    address internal keeper = vm.addr(0xB2);
    address internal subscriber = vm.addr(0xC3);
    address internal merchant = vm.addr(0xD4);

    function setUp() public {
        vm.startPrank(owner);
        vault = new SubscriptionVault4337(keeper);
        token = new MockERC20("Mock", "MCK", 6);
        vault.setTokenAllowed(address(token), true);
        vm.stopPrank();

        token.mint(subscriber, type(uint128).max);
        vm.prank(subscriber);
        token.approve(address(vault), type(uint256).max);
    }

    /// @notice L'ÉCHÉANCE AVANCE TOUJOURS STRICTEMENT.
    ///
    /// La propriété qui empêche un keeper de rappeler `processSubscription`
    /// en boucle dans le même bloc et de vider un abonné. Elle repose sur
    /// `MIN_PERIOD` : si quelqu'un retire un jour ce `require`, une période
    /// de zéro seconde rendrait `nextPaymentTime` immobile — et le
    /// `require(block.timestamp >= nextPaymentTime)` laisserait alors passer
    /// une charge par appel, sans limite.
    ///
    /// Un fuzzer ne trouvera jamais ce cas : il faudrait qu'il tire
    /// exactement `periodSeconds == 0` APRÈS que la garde ait disparu. Le
    /// solveur, lui, cherche le contre-exemple par construction.
    function check_nextPaymentTimeAlwaysStrictlyAdvances(
        uint256 periodSeconds,
        uint256 amount,
        uint256 warpTo
    ) public {
        vm.assume(amount > 0 && amount < type(uint96).max);
        vm.assume(periodSeconds >= vault.MIN_PERIOD());
        vm.assume(periodSeconds < 365 days);
        vm.assume(warpTo > block.timestamp && warpTo < block.timestamp + 3650 days);

        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(token), amount, periodSeconds, block.timestamp, 0
        );

        (,,,,, uint256 avant,,) = vault.subscriptions(id);
        vm.warp(warpTo);

        vm.prank(keeper);
        vault.processSubscription(id);

        (,,,,, uint256 apres,,) = vault.subscriptions(id);
        assert(apres > avant);
        assert(apres > block.timestamp);
    }

    /// @notice LE MONTANT PRÉLEVÉ EST EXACTEMENT CELUI QUI A ÉTÉ SIGNÉ.
    ///
    /// Le keeper déclenche le prélèvement, il ne le paramètre pas. Ni le
    /// montant, ni le destinataire ne sont fournis par l'appelant : ils
    /// viennent de la souscription enregistrée. Cette phrase est le cœur du
    /// modèle de confiance — un client autorise des TERMES, pas un pouvoir.
    function check_keeperCannotAlterTheChargedAmount(
        uint256 amount,
        uint256 periodSeconds
    ) public {
        vm.assume(amount > 0 && amount < type(uint96).max);
        vm.assume(periodSeconds >= vault.MIN_PERIOD() && periodSeconds < 365 days);

        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(token), amount, periodSeconds, block.timestamp, 0
        );

        uint256 soldeAbonneAvant = token.balanceOf(subscriber);
        uint256 soldeMarchandAvant = token.balanceOf(merchant);

        vm.prank(keeper);
        vault.processSubscription(id);

        assert(token.balanceOf(subscriber) == soldeAbonneAvant - amount);
        assert(token.balanceOf(merchant) == soldeMarchandAvant + amount);
    }

    /// @notice LE COFFRE NE DÉTIENT JAMAIS DE FONDS — la garde 3, prouvée.
    ///
    /// Le jumeau symbolique de `invariant_VaultHoldsNoTokens`. Le fuzzer le
    /// vérifie sur les séquences qu'il a tirées ; ici, la phrase vaut pour
    /// TOUT montant et TOUTE période admissibles.
    ///
    /// LES DEUX `vm.assume` SUR LES ADRESSES — mesuré le 2026-09-01, halmos
    /// 0.3.3, première exécution réelle de ce fichier. Sans eux, la propriété
    /// était RÉFUTÉE, avec un contre-exemple à deux paramètres et un coffre qui
    /// ne touche jamais un jeton. La cause n'est pas dans le contrat :
    /// `vm.addr(k)` rend à halmos une adresse SYMBOLIQUE (`f_vmaddr(k)`),
    /// distincte des autres `vm.addr` mais libre de coïncider avec n'importe
    /// quelle adresse concrète — dont celle du coffre lui-même. Le solveur a
    /// donc choisi « le marchand EST le coffre » : le prélèvement crédite
    /// alors le coffre, et l'assertion tombe. Quatre expériences l'ont isolé :
    /// la même assertion sur une adresse jamais écrite tombait aussi (le
    /// souscripteur pouvant être cette adresse, et `mint` l'ayant créditée),
    /// et elle tient dès que les deux acteurs sont supposés distincts du
    /// coffre — en forme absolue comme en forme delta.
    ///
    /// CE QUE L'HYPOTHÈSE EXCLUT EST UN VRAI COIN, PAS UN ARTEFACT : rien dans
    /// `_create` n'interdit `recipient == address(this)`. Un souscripteur qui
    /// signerait un tel abonnement enverrait ses jetons dans un contrat sans
    /// aucune fonction de sortie — bloqués, pas volés, et par sa seule main.
    /// Ce n'est pas une preuve de plus à écrire ici, c'est une décision de
    /// contrat (un `require` de plus, donc un redéploiement) : D-060.
    function check_vaultNeverCustodiesFunds(
        uint256 amount,
        uint256 periodSeconds
    ) public {
        vm.assume(amount > 0 && amount < type(uint96).max);
        vm.assume(periodSeconds >= vault.MIN_PERIOD() && periodSeconds < 365 days);
        vm.assume(subscriber != address(vault));
        vm.assume(merchant != address(vault));

        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(token), amount, periodSeconds, block.timestamp, 0
        );

        vm.prank(keeper);
        vault.processSubscription(id);

        assert(token.balanceOf(address(vault)) == 0);
    }
}
