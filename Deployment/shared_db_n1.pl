% n1 is the conservative public node.
% Hosts the human/1 facts that n2's distributed `mortal/1` chain pulls in
% over rpc/2-3.

deployment_node(n1).

:- dynamic human/1.

human(plato).
human(aristotle).

% Owner-curated contract, surfaced via /node_info (harvested by a discovery hub).
provides(human/1).


/* Here's a first version of a set of exercises for practising the querying
of a simple Prolog database, in this case a movie database (see below).
Modified from exercises found on the web. Not sure who first made them.  */


/* EXERCISES

Part 1: Write queries to answer the following questions.

    a. In which year was the movie American Beauty released?
    b. Find the movies released in the year 2000.
    c. Find the movies released before 2000.
    d. Find the movies released after 1990.
    e. Find an actor who has appeared in more than one movie.
    f. Find a director of a movie in which Scarlett Johansson appeared.
    g. Find an actor who has also directed a movie.
    h. Find an actor or actress who has also directed a movie.
    i. Find the movie in which John Goodman and Jeff Bridges were co-stars.

Part 2: Add rules to the database to do the following,

    a. released_after(M, Y) <- the movie was released after the given year.
    b. released_before(M, Y) <- the movie was released before the given year.
    c. same_year(M1, M2) <- the movies are released in the same year.
    d. co_star(A1, A2) <- the actor/actress are in the same movie.

*/

/** <examples> (Remove these if you want to give the exercises to students!)

?- movie(american_beauty, Y).
?- movie(M, 2000).
?- movie(M, Y), Y < 2000.
?- movie(M, Y), Y > 1999.
?- actor(M1, A, _), actor(M2, A, _), M1 @> M2.
?- actress(M, scarlett_johansson, _), director(M, D).
?- actor(_, A, _), director(_, A).
?- (actor(_, A, _) ; actress(_, A, _)), director(_, A).
?- actor(M, john_goodman, _), actor(M, jeff_bridges, _).
*/

/* DATABASE

    movie(M, Y) <- movie M came out in year Y
    director(M, D) <- movie M was directed by director D
    actor(M, A, R) <- actor A played role R in movie M
    actress(M, A, R) <- actress A played role R in movie M

*/

:- discontiguous
        movie/2,
        director/2,
        actor/3,
        actress/3.

movie(american_beauty, 1999).
director(american_beauty, sam_mendes).
actor(american_beauty, kevin_spacey, lester_burnham).
actress(american_beauty, annette_bening, carolyn_burnham).
actress(american_beauty, thora_birch, jane_burnham).
actor(american_beauty, wes_bentley, ricky_fitts).
actress(american_beauty, mena_suvari, angela_hayes).
actor(american_beauty, chris_cooper, col_frank_fitts_usmc).
actor(american_beauty, peter_gallagher, buddy_kane).
actress(american_beauty, allison_janney, barbara_fitts).
actor(american_beauty, scott_bakula, jim_olmeyer).
actor(american_beauty, sam_robards, jim_berkley).
actor(american_beauty, barry_del_sherman, brad_dupree).
actress(american_beauty, ara_celi, sale_house_woman_1).
actor(american_beauty, john_cho, sale_house_man_1).
actor(american_beauty, fort_atkinson, sale_house_man_2).
actress(american_beauty, sue_casey, sale_house_woman_2).
actor(american_beauty, kent_faulcon, sale_house_man_3).
actress(american_beauty, brenda_wehle, sale_house_woman_4).
actress(american_beauty, lisa_cloud, sale_house_woman_5).
actress(american_beauty, alison_faulk, spartanette_1).
actress(american_beauty, krista_goodsitt, spartanette_2).
actress(american_beauty, lily_houtkin, spartanette_3).
actress(american_beauty, carolina_lancaster, spartanette_4).
actress(american_beauty, romana_leah, spartanette_5).
actress(american_beauty, chekeshka_van_putten, spartanette_6).
actress(american_beauty, emily_zachary, spartanette_7).
actress(american_beauty, nancy_anderson, spartanette_8).
actress(american_beauty, reshma_gajjar, spartanette_9).
actress(american_beauty, stephanie_rizzo, spartanette_10).
actress(american_beauty, heather_joy_sher, playground_girl_1).
actress(american_beauty, chelsea_hertford, playground_girl_2).
actress(american_beauty, amber_smith, christy_kane).
actor(american_beauty, joel_mccrary, catering_boss).
actress(american_beauty, marissa_jaret_winokur, mr_smiley_s_counter_girl).
actor(american_beauty, dennis_anderson, mr_smiley_s_manager).
actor(american_beauty, matthew_kimbrough, firing_range_attendant).
actress(american_beauty, erin_cathryn_strubbe, young_jane_burnham).
actress(american_beauty, elaine_corral_kendall, newscaster).

movie(anna, 1987).
director(anna, yurek_bogayevicz).
actress(anna, sally_kirkland, anna).
actor(anna, robert_fields, daniel).
actress(anna, paulina_porizkova, krystyna).
actor(anna, gibby_brand, director_1).
actor(anna, john_robert_tillotson, director_2).
actress(anna, julianne_gilliam, woman_author).
actor(anna, joe_aufiery, stage_manager).
actor(anna, lance_davis, assistant_1).
actress(anna, deirdre_o_connell, assistant_2).
actress(anna, ruth_maleczech, woman_1_woman_named_gloria).
actress(anna, holly_villaire, woman_2_woman_with_bird).
actress(anna, shirl_bernheim, woman_3_woman_in_white_veil).
actress(anna, ren_e_coleman, woman_4_woman_in_bonnet).
actress(anna, gabriela_farrar, woman_5_woman_in_black).
actress(anna, jordana_levine, woman_6_woman_in_turban).
actress(anna, rosalie_traina, woman_7_woman_in_gold).
actress(anna, maggie_wagner, actress_d).
actor(anna, charles_randall, agent).
actress(anna, mimi_weddell, agent_s_secretary).
actor(anna, larry_pine, baskin).
actress(anna, lola_pashalinski, producer).
actor(anna, stefan_schnabel, professor).
actor(anna, steven_gilborn, tonda).
actor(anna, rand_stone, george).
actress(anna, geena_goodwin, daniel_s_mother).
actor(anna, david_r_ellis, daniel_s_father).
actor(anna, brian_kohn, jonathan).
actress(anna, caroline_aaron, interviewer).
actor(anna, vasek_simek, czech_demonstrator_1).
actor(anna, paul_leski, czech_demonstrator_2).
actor(anna, larry_attile, czech_demonstrator_3).
actress(anna, sofia_coppola, noodle).
actor(anna, theo_mayes, dancing_dishwasher).
actress(anna, nina_port, dancing_dishwasher).

movie(barton_fink, 1991).
director(barton_fink, ethan_coen).
director(barton_fink, joel_coen).
actor(barton_fink, john_turturro, barton_fink).
actor(barton_fink, john_goodman, charlie_meadows).
actress(barton_fink, judy_davis, audrey_taylor).
actor(barton_fink, michael_lerner, jack_lipnick).
actor(barton_fink, john_mahoney, w_p_mayhew).
actor(barton_fink, tony_shalhoub, ben_geisler).
actor(barton_fink, jon_polito, lou_breeze).
actor(barton_fink, steve_buscemi, chet).
actor(barton_fink, david_warrilow, garland_stanford).
actor(barton_fink, richard_portnow, detective_mastrionotti).
actor(barton_fink, christopher_murney, detective_deutsch).
actor(barton_fink, i_m_hobson, derek).
actress(barton_fink, meagen_fay, poppy_carnahan).
actor(barton_fink, lance_davis, richard_st_claire).
actor(barton_fink, harry_bugin, pete).
actor(barton_fink, anthony_gordon, maitre_d).
actor(barton_fink, jack_denbo, stagehand).
actor(barton_fink, max_grod_nchik, clapper_boy).
actor(barton_fink, robert_beecher, referee).
actor(barton_fink, darwyn_swalve, wrestler).
actress(barton_fink, gayle_vance, geisler_s_secretary).
actor(barton_fink, johnny_judkins, sailor).
actress(barton_fink, jana_marie_hupp, uso_girl).
actress(barton_fink, isabelle_townsend, beauty).
actor(barton_fink, william_preston_robertson, voice).

movie(the_big_lebowski, 1998).
director(the_big_lebowski, joel_coen).
actor(the_big_lebowski, jeff_bridges, jeffrey_lebowski__the_dude).
actor(the_big_lebowski, john_goodman, walter_sobchak).
actress(the_big_lebowski, julianne_moore, maude_lebowski).
actor(the_big_lebowski, steve_buscemi, theodore_donald_donny_kerabatsos).
actor(the_big_lebowski, david_huddleston, jeffrey_lebowski__the_big_lebowski).
actor(the_big_lebowski, philip_seymour_hoffman, brandt).
actress(the_big_lebowski, tara_reid, bunny_lebowski).
actor(the_big_lebowski, philip_moon, woo_treehorn_thug).
actor(the_big_lebowski, mark_pellegrino, blond_treehorn_thug).
actor(the_big_lebowski, peter_stormare, uli_kunkel_nihilist_1__karl_hungus).
actor(the_big_lebowski, flea, nihilist_2).
actor(the_big_lebowski, torsten_voges, nihilist_3).
actor(the_big_lebowski, jimmie_dale_gilmore, smokey).
actor(the_big_lebowski, jack_kehler, marty).
actor(the_big_lebowski, john_turturro, jesus_quintana).
actor(the_big_lebowski, james_g_hoosier, liam_o_brien).
actor(the_big_lebowski, carlos_leon, maude_s_thug).
actor(the_big_lebowski, terrence_burton, maude_s_thug).
actor(the_big_lebowski, richard_gant, older_cop).
actor(the_big_lebowski, christian_clemenson, younger_cop).
actor(the_big_lebowski, dom_irrera, tony_the_chauffeur).
actor(the_big_lebowski, g_rard_l_heureux, lebowski_s_chauffeur).
actor(the_big_lebowski, david_thewlis, knox_harrington).
actress(the_big_lebowski, lu_elrod, coffee_shop_waitress).
actor(the_big_lebowski, mike_gomez, auto_circus_cop).
actor(the_big_lebowski, peter_siragusa, gary_the_bartender).
actor(the_big_lebowski, sam_elliott, the_stranger).
actor(the_big_lebowski, marshall_manesh, doctor).
actor(the_big_lebowski, harry_bugin, arthur_digby_sellers).
actor(the_big_lebowski, jesse_flanagan, little_larry_sellers).
actress(the_big_lebowski, irene_olga_l_pez, pilar_sellers_housekeeper).
actor(the_big_lebowski, luis_colina, corvette_owner).
actor(the_big_lebowski, ben_gazzara, jackie_treehorn).
actor(the_big_lebowski, leon_russom, malibu_police_chief).
actor(the_big_lebowski, ajgie_kirkland, cab_driver).
actor(the_big_lebowski, jon_polito, da_fino).
actress(the_big_lebowski, aimee_mann, nihilist_woman).
actor(the_big_lebowski, jerry_haleva, saddam_hussein).
actress(the_big_lebowski, jennifer_lamb, pancake_waitress).
actor(the_big_lebowski, warren_keith, funeral_director).
actress(the_big_lebowski, wendy_braun, chorine_dancer).
actress(the_big_lebowski, asia_carrera, sherry_in_logjammin).
actress(the_big_lebowski, kiva_dawson, dancer).
actress(the_big_lebowski, robin_jones, checker_at_ralph_s).
actor(the_big_lebowski, paris_themmen, '').

movie(blade_runner, 1997).
director(blade_runner, joseph_d_kucan).
actor(blade_runner, martin_azarow, dino_klein).
actor(blade_runner, lloyd_bell, additional_voices).
actor(blade_runner, mark_benninghoffen, ray_mccoy).
actor(blade_runner, warren_burton, runciter).
actress(blade_runner, gwen_castaldi, dispatcher_and_newscaster).
actress(blade_runner, signy_coleman, dektora).
actor(blade_runner, gary_columbo, general_doll).
actor(blade_runner, jason_cottle, luthur_lance_photographer).
actor(blade_runner, timothy_dang, izo).
actor(blade_runner, gerald_deloff, additional_voices).
actress(blade_runner, lisa_edelstein, crystal_steele).
actor(blade_runner, gary_l_freeman, additional_voices).
actor(blade_runner, jeff_garlin, lieutenant_edison_guzza).
actor(blade_runner, eric_gooch, additional_voices).
actor(blade_runner, javier_grajeda, gaff).
actor(blade_runner, mike_grayford, additional_voices).
actress(blade_runner, gloria_hoffmann, mia).
actor(blade_runner, james_hong, dr_chew).
actress(blade_runner, kia_huntzinger, additional_voices).
actor(blade_runner, anthony_izzo, officer_leary).
actor(blade_runner, brion_james, leon).
actress(blade_runner, shelly_johnson, additional_voices).
actor(blade_runner, terry_jourden, spencer_grigorian).
actor(blade_runner, jerry_kernion, holloway).
actor(blade_runner, joseph_d_kucan, crazylegs_larry).
actor(blade_runner, jerry_lan, murray).
actor(blade_runner, michael_b_legg, additional_voices).
actor(blade_runner, demarlo_lewis, additional_voices).
actor(blade_runner, tse_cheng_lo, additional_voices).
actress(blade_runner, etsuko_mader, additional_voices).
actor(blade_runner, mohanned_mansour, additional_voices).
actress(blade_runner, karen_maruyama, fish_dealer).
actor(blade_runner, michael_mcshane, marcus_eisenduller).
actor(blade_runner, alexander_mervin, sadik).
actor(blade_runner, tony_mitch, governor_kolvig).
actor(blade_runner, toru_nagai, howie_lee).
actor(blade_runner, dwight_k_okahara, additional_voices).
actor(blade_runner, gerald_okamura, zuben).
actor(blade_runner, bruno_oliver, gordo_frizz).
actress(blade_runner, pauley_perrette, lucy_devlin).
actor(blade_runner, mark_rolston, clovis).
actor(blade_runner, stephen_root, early_q).
actor(blade_runner, william_sanderson, j_f_sebastian).
actor(blade_runner, vincent_schiavelli, bullet_bob).
actress(blade_runner, rosalyn_sidewater, isabella).
actor(blade_runner, ron_snow, blimp_announcer).
actor(blade_runner, stephen_sorrentino, shoeshine_man_hasan).
actress(blade_runner, jessica_straus, answering_machine_female_announcer).
actress(blade_runner, melonie_sung, additional_voices).
actor(blade_runner, iqbal_theba, moraji).
actress(blade_runner, myriam_tubert, insect_dealer).
actor(blade_runner, joe_turkel, eldon_tyrell).
actor(blade_runner, bill_wade, hanoi).
actor(blade_runner, jim_walls, additional_voices).
actress(blade_runner, sandra_wang, additional_voices).
actor(blade_runner, marc_worden, baker).
actress(blade_runner, sean_young, rachael).
actor(blade_runner, joe_tippy_zeoli, officer_grayford).

movie(blood_simple, 1984).
director(blood_simple, ethan_coen).
director(blood_simple, joel_coen).
actor(blood_simple, john_getz, ray).
actress(blood_simple, frances_mcdormand, abby).
actor(blood_simple, dan_hedaya, julian_marty).
actor(blood_simple, m_emmet_walsh, loren_visser_private_detective).
actor(blood_simple, samm_art_williams, meurice).
actress(blood_simple, deborah_neumann, debra).
actress(blood_simple, raquel_gavia, landlady).
actor(blood_simple, van_brooks, man_from_lubbock).
actor(blood_simple, se_or_marco, mr_garcia).
actor(blood_simple, william_creamer, old_cracker).
actor(blood_simple, loren_bivens, strip_bar_exhorter).
actor(blood_simple, bob_mcadams, strip_bar_exhorter).
actress(blood_simple, shannon_sedwick, stripper).
actress(blood_simple, nancy_finger, girl_on_overlook).
actor(blood_simple, william_preston_robertson, radio_evangelist).
actress(blood_simple, holly_hunter, helene_trend).
actor(blood_simple, barry_sonnenfeld, marty_s_vomiting).

movie(the_cotton_club, 1984).
director(the_cotton_club, francis_ford_coppola).
actor(the_cotton_club, richard_gere, michael_dixie_dwyer).
actor(the_cotton_club, gregory_hines, sandman_williams).
actress(the_cotton_club, diane_lane, vera_cicero).
actress(the_cotton_club, lonette_mckee, lila_rose_oliver).
actor(the_cotton_club, bob_hoskins, owney_madden).
actor(the_cotton_club, james_remar, dutch_schultz).
actor(the_cotton_club, nicolas_cage, vincent_dwyer).
actor(the_cotton_club, allen_garfield, abbadabba_berman).
actor(the_cotton_club, fred_gwynne, frenchy_demange).
actress(the_cotton_club, gwen_verdon, tish_dwyer).
actress(the_cotton_club, lisa_jane_persky, frances_flegenheimer).
actor(the_cotton_club, maurice_hines, clay_williams).
actor(the_cotton_club, julian_beck, sol_weinstein).
actress(the_cotton_club, novella_nelson, madame_st_clair).
actor(the_cotton_club, laurence_fishburne, bumpy_rhodes).
actor(the_cotton_club, john_p_ryan, joe_flynn).
actor(the_cotton_club, tom_waits, irving_stark).
actor(the_cotton_club, ron_karabatsos, mike_best).
actor(the_cotton_club, glenn_withrow, ed_popke).
actress(the_cotton_club, jennifer_grey, patsy_dwyer).
actress(the_cotton_club, wynonna_smith, winnie_williams).
actress(the_cotton_club, thelma_carpenter, norma_williams).
actor(the_cotton_club, charles_honi_coles, suger_coates).
actor(the_cotton_club, larry_marshall, cab_calloway_minnie_the_moocher__lady_with_the_fan_and_jitterbug_sung_by).
actor(the_cotton_club, joe_dallesandro, charles_lucky_luciano).
actor(the_cotton_club, ed_o_ross, monk).
actor(the_cotton_club, frederick_downs_jr, sullen_man).
actress(the_cotton_club, diane_venora, gloria_swanson).
actor(the_cotton_club, tucker_smallwood, kid_griffin).
actor(the_cotton_club, woody_strode, holmes).
actor(the_cotton_club, bill_graham, j_w).
actor(the_cotton_club, dayton_allen, solly).
actor(the_cotton_club, kim_chan, ling).
actor(the_cotton_club, ed_rowan, messiah).
actor(the_cotton_club, leonard_termo, danny).
actor(the_cotton_club, george_cantero, vince_hood).
actor(the_cotton_club, brian_tarantina, vince_hood).
actor(the_cotton_club, bruce_macvittie, vince_hood).
actor(the_cotton_club, james_russo, vince_hood).
actor(the_cotton_club, giancarlo_esposito, bumpy_hood).
actor(the_cotton_club, bruce_hubbard, bumpy_hood).
actor(the_cotton_club, rony_clanton, caspar_holstein).
actor(the_cotton_club, damien_leake, bub_jewett).
actor(the_cotton_club, bill_cobbs, big_joe_ison).
actor(the_cotton_club, joe_lynn, marcial_flores).
actor(the_cotton_club, oscar_barnes, spanish_henry).
actor(the_cotton_club, ed_zang, hotel_clerk).
actress(the_cotton_club, sandra_beall, myrtle_fay).
actor(the_cotton_club, zane_mark, duke_ellington).
actor(the_cotton_club, tom_signorelli, butch_murdock).
actor(the_cotton_club, paul_herman, policeman_1).
actor(the_cotton_club, randle_mell, policeman_2).
actor(the_cotton_club, steve_vignari, trigger_mike_coppola).
actress(the_cotton_club, susan_mechsner, gypsie).
actor(the_cotton_club, gregory_rozakis, charlie_chaplin).
actor(the_cotton_club, marc_coppola, ted_husing).
actress(the_cotton_club, norma_jean_darden, elda_webb).
actor(the_cotton_club, robert_earl_jones, stage_door_joe).
actor(the_cotton_club, vincent_jerosa, james_cagney).
actress(the_cotton_club, rosalind_harris, fanny_brice).
actor(the_cotton_club, steve_cafiso, child_in_street).
actor(the_cotton_club, john_cafiso, child_in_street).
actress(the_cotton_club, sofia_coppola, child_in_street).
actress(the_cotton_club, ninon_digiorgio, child_in_street).
actress(the_cotton_club, daria_hines, child_in_street).
actress(the_cotton_club, patricia_letang, child_in_street).
actor(the_cotton_club, christopher_lewis, child_in_street).
actress(the_cotton_club, danielle_osborne, child_in_street).
actor(the_cotton_club, jason_papalardo, child_in_street).
actor(the_cotton_club, demetrius_pena, child_in_street).
actress(the_cotton_club, priscilla_baskerville, creole_love_call_sung_by).
actress(the_cotton_club, ethel_beatty, bandana_babies_lead_vocal_dancer).
actress(the_cotton_club, sydney_goldsmith, barbecue_bess_sung_by).
actor(the_cotton_club, james_buster_brown, hoofer).
actor(the_cotton_club, ralph_brown, hoofer).
actor(the_cotton_club, harold_cromer, hoofer).
actor(the_cotton_club, bubba_gaines, hoofer).
actor(the_cotton_club, george_hillman, hoofer).
actor(the_cotton_club, henry_phace_roberts, hoofer).
actor(the_cotton_club, howard_sandman_sims, hoofer).
actor(the_cotton_club, jimmy_slyde, hoofer).
actor(the_cotton_club, henry_letang, hoofer).
actor(the_cotton_club, charles_young, hoofer).
actor(the_cotton_club, skip_cunningham, tip_tap__toe).
actor(the_cotton_club, luther_fontaine, tip_tap__toe).
actor(the_cotton_club, jan_mickens, tip_tap__toe).
actress(the_cotton_club, lydia_abarca, dancer).
actress(the_cotton_club, sarita_allen, dancer).
actress(the_cotton_club, tracey_bass, dancer).
actress(the_cotton_club, jacquelyn_bird, dancer).
actress(the_cotton_club, shirley_black_brown, dancer).
actress(the_cotton_club, jhoe_breedlove, dancer).
actor(the_cotton_club, lester_brown, dancer).
actress(the_cotton_club, leslie_caldwell, dancer).
actress(the_cotton_club, melanie_caldwell, dancer).
actor(the_cotton_club, benny_clorey, dancer).
actress(the_cotton_club, sheri_cowart, dancer).
actress(the_cotton_club, karen_dibianco, dancer).
actress(the_cotton_club, cisco_drayton, dancer).
actress(the_cotton_club, anne_duquesnay, dancer).
actress(the_cotton_club, carla_earle, dancer).
actress(the_cotton_club, wendy_edmead, dancer).
actress(the_cotton_club, debbie_fitts, dancer).
actor(the_cotton_club, ruddy_l_garner, dancer).
actress(the_cotton_club, ruthanna_graves, dancer).
actress(the_cotton_club, terri_griffin, dancer).
actress(the_cotton_club, robin_harmon, dancer).
actress(the_cotton_club, jackee_harree, dancer).
actress(the_cotton_club, sonya_hensley, dancer).
actor(the_cotton_club, dave_jackson, dancer).
actress(the_cotton_club, gail_kendricks, dancer).
actress(the_cotton_club, christina_kumi_kimball, dancer).
actress(the_cotton_club, mary_beth_kurdock, dancer).
actor(the_cotton_club, alde_lewis, dancer).
actress(the_cotton_club, paula_lynn, dancer).
actor(the_cotton_club, bernard_manners, dancer).
actor(the_cotton_club, bernard_marsh, dancer).
actor(the_cotton_club, david_mcharris, dancer).
actress(the_cotton_club, delores_mcharris, dancer).
actress(the_cotton_club, vody_najac, dancer).
actress(the_cotton_club, vya_negromonte, dancer).
actress(the_cotton_club, alice_anne_oates, dancer).
actress(the_cotton_club, anne_palmer, dancer).
actress(the_cotton_club, julie_pars, dancer).
actress(the_cotton_club, antonia_pettiford, dancer).
actress(the_cotton_club, valarie_pettiford, dancer).
actress(the_cotton_club, janet_powell, dancer).
actress(the_cotton_club, renee_rodriguez, dancer).
actress(the_cotton_club, tracey_ross, dancer).
actress(the_cotton_club, kiki_shepard, dancer).
actor(the_cotton_club, gary_thomas, dancer).
actor(the_cotton_club, mario_van_peebles, dancer).
actress(the_cotton_club, rima_vetter, dancer).
actress(the_cotton_club, karen_wadkins, dancer).
actor(the_cotton_club, ivery_wheeler, dancer).
actor(the_cotton_club, donald_williams, dancer).
actress(the_cotton_club, alexis_wilson, dancer).
actor(the_cotton_club, george_coutoupis, gangster).
actor(the_cotton_club, nicholas_j_giangiulio, screen_test_thug).
actress(the_cotton_club, suzanne_kaaren, the_duchess_of_park_avenue).
actor(the_cotton_club, mark_margolis, gunman_sooting_cage_s_character).
actor(the_cotton_club, kirk_taylor, cotton_club_waiter).
actor(the_cotton_club, stan_tracy, legs_diamond_s_bodyguard).
actor(the_cotton_club, rick_washburn, hitman).

movie(cq, 2001).
director(cq, roman_coppola).
actor(cq, jeremy_davies, paul).
actress(cq, angela_lindvall, dragonfly_valentine).
actress(cq, lodie_bouchez, marlene).
actor(cq, g_rard_depardieu, andrezej).
actor(cq, giancarlo_giannini, enzo).
actor(cq, massimo_ghini, fabrizio).
actor(cq, jason_schwartzman, felix_demarco).
actor(cq, billy_zane, mr_e).
actor(cq, john_phillip_law, chairman).
actor(cq, silvio_muccino, pippo).
actor(cq, dean_stockwell, dr_ballard).
actress(cq, natalia_vodianova, brigit).
actor(cq, bernard_verley, trailer_voiceover_actor).
actor(cq, l_m_kit_carson, fantasy_critic).
actor(cq, chris_bearne, fantasy_critic).
actor(cq, jean_paul_scarpitta, fantasy_critic).
actor(cq, nicolas_saada, fantasy_critic).
actor(cq, remi_fourquin, fantasy_critic).
actor(cq, jean_claude_schlim, fantasy_critic).
actress(cq, sascha_ley, fantasy_critic).
actor(cq, jacques_deglas, fantasy_critic).
actor(cq, gilles_soeder, fantasy_critic).
actor(cq, julian_nest, festival_critic).
actress(cq, greta_seacat, festival_critic).
actress(cq, barbara_sarafian, festival_critic).
actor(cq, leslie_woodhall, board_member).
actor(cq, jean_baptiste_kremer, board_member).
actor(cq, franck_sasonoff, angry_man_at_riots).
actor(cq, jean_fran_ois_wolff, party_man).
actor(cq, eric_connor, long_haired_actor_at_party).
actress(cq, diana_gartner, cute_model_at_party).
actress(cq, st_phanie_gesnel, actress_at_party).
actor(cq, fr_d_ric_de_brabant, steward).
actor(cq, shawn_mortensen, revolutionary_guard).
actor(cq, matthieu_tonetti, revolutionary_guard).
actress(cq, ann_maes, vampire_actress).
actress(cq, gintare_parulyte, vampire_actress).
actress(cq, caroline_lies, vampire_actress).
actress(cq, stoyanka_tanya_gospodinova, vampire_actress).
actress(cq, magali_dahan, vampire_actress).
actress(cq, natalie_broker, vampire_actress).
actress(cq, wanda_perdelwitz, vampire_actress).
actor(cq, mark_thompson_ashworth, lead_ghoul).
actor(cq, pieter_riemens, assistant_director).
actress(cq, federica_citarella, talkative_girl).
actor(cq, andrea_cormaci, soldier_boy).
actress(cq, corinne_terenzi, teen_lover).
actress(cq, sofia_coppola, enzo_s_mistress).
actor(cq, emidio_la_vella, italian_actor).
actor(cq, massimo_schina, friendly_guy_at_party).
actress(cq, caroline_colombini, girl_in_miniskirt).
actress(cq, rosa_pianeta, woman_in_fiat).
actor(cq, christophe_chrompin, jealous_boyfriend).
actor(cq, romain_duris, hippie_filmmaker).
actor(cq, chris_anthony, second_assistant_director).
actor(cq, dean_tavoularis, man_at_screening).

movie(crimewave, 1985).
director(crimewave, sam_raimi).
actress(crimewave, louise_lasser, helene_trend).
actor(crimewave, paul_l_smith, faron_crush).
actor(crimewave, brion_james, arthur_coddish).
actress(crimewave, sheree_j_wilson, nancy).
actor(crimewave, edward_r_pressman, ernest_trend).
actor(crimewave, bruce_campbell, renaldo_the_heel).
actor(crimewave, reed_birney, vic_ajax).
actor(crimewave, richard_bright, officer_brennan).
actor(crimewave, antonio_fargas, blind_man).
actor(crimewave, hamid_dana, donald_odegard).
actor(crimewave, john_hardy, mr_yarman).
actor(crimewave, emil_sitka, colonel_rodgers).
actor(crimewave, hal_youngblood, jack_elroy).
actor(crimewave, sean_farley, jack_elroy_jr).
actor(crimewave, richard_demanincor, officer_garvey).
actress(crimewave, carrie_hall, cheap_dish).
actor(crimewave, wiley_harker, governor).
actor(crimewave, julius_harris, hardened_convict).
actor(crimewave, ralph_drischell, executioner).
actor(crimewave, robert_symonds, guard_1).
actor(crimewave, patrick_stack, guard_2).
actor(crimewave, philip_a_gillis, priest).
actress(crimewave, bridget_hoffman, nun).
actress(crimewave, ann_marie_gillis, nun).
actress(crimewave, frances_mcdormand, nun).
actress(crimewave, carol_brinn, old_woman).
actor(crimewave, matthew_taylor, muscleman).
actor(crimewave, perry_mallette, grizzled_veteran).
actor(crimewave, chuck_gaidica, weatherman).
actor(crimewave, jimmie_launce, announcer).
actor(crimewave, joseph_french, bandleader).
actor(crimewave, ted_raimi, waiter).
actor(crimewave, dennis_chaitlin, fat_waiter).
actor(crimewave, joel_coen, reporter_at_execution).
actress(crimewave, julie_harris, '').
actor(crimewave, dan_nelson, waiter).

movie(down_from_the_mountain, 2000).
director(down_from_the_mountain, nick_doob).
director(down_from_the_mountain, chris_hegedus).
director(down_from_the_mountain, d_a_pennebaker).
actress(down_from_the_mountain, evelyn_cox, herself).
actor(down_from_the_mountain, sidney_cox, himself).
actress(down_from_the_mountain, suzanne_cox, herself).
actor(down_from_the_mountain, willard_cox, himself).
actor(down_from_the_mountain, nathan_best, himself).
actor(down_from_the_mountain, issac_freeman, himself).
actor(down_from_the_mountain, robert_hamlett, himself).
actor(down_from_the_mountain, joseph_rice, himself).
actor(down_from_the_mountain, wilson_waters_jr, himself).
actor(down_from_the_mountain, john_hartford, himself).
actor(down_from_the_mountain, larry_perkins, himself).
actress(down_from_the_mountain, emmylou_harris, herself).
actor(down_from_the_mountain, chris_thomas_king, himself).
actress(down_from_the_mountain, alison_krauss, herself).
actor(down_from_the_mountain, colin_linden, himself).
actor(down_from_the_mountain, pat_enright, himself).
actor(down_from_the_mountain, gene_libbea, himself).
actor(down_from_the_mountain, alan_o_bryant, himself).
actor(down_from_the_mountain, roland_white, himself).
actress(down_from_the_mountain, hannah_peasall, herself).
actress(down_from_the_mountain, leah_peasall, herself).
actress(down_from_the_mountain, sarah_peasall, herself).
actor(down_from_the_mountain, ralph_stanley, himself).
actress(down_from_the_mountain, gillian_welch, herself).
actor(down_from_the_mountain, david_rawlings, himself).
actor(down_from_the_mountain, buck_white, himself).
actress(down_from_the_mountain, cheryl_white, herself).
actress(down_from_the_mountain, sharon_white, herself).
actor(down_from_the_mountain, barry_bales, house_band_bass).
actor(down_from_the_mountain, ron_block, house_band_banjo).
actor(down_from_the_mountain, mike_compton, house_band_mandolin).
actor(down_from_the_mountain, jerry_douglas, house_band_dobro).
actor(down_from_the_mountain, stuart_duncan, house_band_fiddle).
actor(down_from_the_mountain, chris_sharp, house_band_guitar).
actor(down_from_the_mountain, dan_tyminski, house_band_guitar).
actor(down_from_the_mountain, t_bone_burnett, himself).
actor(down_from_the_mountain, ethan_coen, himself).
actor(down_from_the_mountain, joel_coen, himself).
actress(down_from_the_mountain, holly_hunter, herself).
actor(down_from_the_mountain, tim_blake_nelson, himself).
actor(down_from_the_mountain, billy_bob_thornton, audience_member).
actor(down_from_the_mountain, wes_motley, audience_member).
actress(down_from_the_mountain, tamara_trexler, audience_member).

movie(fargo, 1996).
director(fargo, ethan_coen).
director(fargo, joel_coen).
actor(fargo, william_h_macy, jerry_lundegaard).
actor(fargo, steve_buscemi, carl_showalter).
actor(fargo, peter_stormare, gaear_grimsrud).
actress(fargo, kristin_rudr_d, jean_lundegaard).
actor(fargo, harve_presnell, wade_gustafson).
actor(fargo, tony_denman, scotty_lundegaard).
actor(fargo, gary_houston, irate_customer).
actress(fargo, sally_wingert, irate_customer_s_wife).
actor(fargo, kurt_schweickhardt, car_salesman).
actress(fargo, larissa_kokernot, hooker_1).
actress(fargo, melissa_peterman, hooker_2).
actor(fargo, steve_reevis, shep_proudfoot).
actor(fargo, warren_keith, reilly_diefenbach).
actor(fargo, steve_edelman, morning_show_host).
actress(fargo, sharon_anderson, morning_show_hostess).
actor(fargo, larry_brandenburg, stan_grossman).
actor(fargo, james_gaulke, state_trooper).
actor(fargo, j_todd_anderson, victim_in_the_field).
actress(fargo, michelle_suzanne_ledoux, victim_in_car).
actress(fargo, frances_mcdormand, marge_gunderson).
actor(fargo, john_carroll_lynch, norm_gunderson).
actor(fargo, bruce_bohne, lou).
actress(fargo, petra_boden, cashier).
actor(fargo, steve_park, mike_yanagita).
actor(fargo, wayne_a_evenson, customer).
actor(fargo, cliff_rakerd, officer_olson).
actress(fargo, jessica_shepherd, hotel_clerk).
actor(fargo, peter_schmitz, airport_lot_attendant).
actor(fargo, steven_i_schafer, mechanic).
actress(fargo, michelle_hutchison, escort).
actor(fargo, david_s_lomax, man_in_hallway).
actor(fargo, jos_feliciano, himself).
actor(fargo, bix_skahill, night_parking_attendant).
actor(fargo, bain_boehlke, mr_mohra).
actress(fargo, rose_stockton, valerie).
actor(fargo, robert_ozasky, bismarck_cop_1).
actor(fargo, john_bandemer, bismarck_cop_2).
actor(fargo, don_wescott, bark_beetle_narrator).
actor(fargo, bruce_campbell, soap_opera_actor).
actor(fargo, clifford_nelson, heavyset_man_in_bar).

movie(the_firm, 1993).
director(the_firm, sydney_pollack).
actor(the_firm, tom_cruise, mitch_mcdeere).
actress(the_firm, jeanne_tripplehorn, abby_mcdeere).
actor(the_firm, gene_hackman, avery_tolar).
actor(the_firm, hal_holbrook, oliver_lambert).
actor(the_firm, terry_kinney, lamar_quinn).
actor(the_firm, wilford_brimley, william_devasher).
actor(the_firm, ed_harris, wayne_tarrance).
actress(the_firm, holly_hunter, tammy_hemphill).
actor(the_firm, david_strathairn, ray_mcdeere).
actor(the_firm, gary_busey, eddie_lomax).
actor(the_firm, steven_hill, f_denton_voyles).
actor(the_firm, tobin_bell, the_nordic_man).
actress(the_firm, barbara_garrick, kay_quinn).
actor(the_firm, jerry_hardin, royce_mcknight).
actor(the_firm, paul_calderon, thomas_richie).
actor(the_firm, jerry_weintraub, sonny_capps).
actor(the_firm, sullivan_walker, barry_abanks).
actress(the_firm, karina_lombard, young_woman_on_beach).
actress(the_firm, margo_martindale, nina_huff).
actor(the_firm, john_beal, nathan_locke).
actor(the_firm, dean_norris, the_squat_man).
actor(the_firm, lou_walker, frank_mulholland).
actress(the_firm, debbie_turner, rental_agent).
actor(the_firm, tommy_cresswell, wally_hudson).
actor(the_firm, david_a_kimball, randall_dunbar).
actor(the_firm, don_jones, attorney).
actor(the_firm, michael_allen, attorney).
actor(the_firm, levi_frazier_jr, restaurant_waiter).
actor(the_firm, brian_casey, telephone_installer).
actor(the_firm, reverend_william_j_parham, minister).
actor(the_firm, victor_nelson, cafe_waiter).
actor(the_firm, richard_ranta, congressman_billings).
actress(the_firm, janie_paris, madge).
actor(the_firm, frank_crawford, judge).
actor(the_firm, bart_whiteman, dutch).
actor(the_firm, david_dwyer, prison_guard).
actor(the_firm, mark_w_johnson, fbi_agent).
actor(the_firm, jerry_chipman, fbi_agent).
actor(the_firm, jimmy_lackie, technician).
actor(the_firm, afemo_omilami, cotton_truck_driver).
actor(the_firm, clint_smith, cotton_truck_driver).
actress(the_firm, susan_elliott, river_museum_guide).
actress(the_firm, erin_branham, river_museum_guide).
actor(the_firm, ed_connelly, pilot).
actress(the_firm, joey_anderson, ruth).
actress(the_firm, deborah_thomas, quinns_maid).
actor(the_firm, tommy_matthews, elvis_aaron_hemphill).
actor(the_firm, chris_schadrack, lawyer_recruiter).
actor(the_firm, buck_ford, lawyer_recruiter).
actor(the_firm, jonathan_kaplan, lawyer_recruiter).
actress(the_firm, rebecca_glenn, young_woman_at_patio_bar).
actress(the_firm, terri_welles, woman_dancing_with_avery).
actor(the_firm, greg_goossen, vietnam_veteran).
actress(the_firm, jeane_aufdenberg, car_rental_agent).
actor(the_firm, william_r_booth, seaplane_pilot).
actor(the_firm, ollie_nightingale, restaurant_singer).
actor(the_firm, teenie_hodges, restaurant_lead_guitarist).
actor(the_firm, little_jimmy_king, memphis_street_musician).
actor(the_firm, james_white, singer_at_hyatt).
actor(the_firm, shan_brisendine, furniture_mover).
actor(the_firm, harry_dach, garbage_truck_driver).
actress(the_firm, julia_hayes, girl_in_bar).
actor(the_firm, tom_mccrory, associate).
actor(the_firm, paul_sorvino, tommie_morolto).
actor(the_firm, joe_viterelli, joey_morolto).

movie(frankenweenie, 1984).
director(frankenweenie, tim_burton).
actress(frankenweenie, shelley_duvall, susan_frankenstein).
actor(frankenweenie, daniel_stern, ben_frankenstein).
actor(frankenweenie, barret_oliver, victor_frankenstein).
actor(frankenweenie, joseph_maher, mr_chambers).
actress(frankenweenie, roz_braverman, mrs_epstein).
actor(frankenweenie, paul_bartel, mr_walsh).
actress(frankenweenie, sofia_coppola, anne_chambers).
actor(frankenweenie, jason_hervey, frank_dale).
actor(frankenweenie, paul_c_scott, mike_anderson).
actress(frankenweenie, helen_boll, mrs_curtis).
actor(frankenweenie, sparky, sparky).
actor(frankenweenie, rusty_james, raymond).

movie(ghost_busters, 1984).
director(ghost_busters, ivan_reitman).
actor(ghost_busters, bill_murray, dr_peter_venkman).
actor(ghost_busters, dan_aykroyd, dr_raymond_stantz).
actress(ghost_busters, sigourney_weaver, dana_barrett).
actor(ghost_busters, harold_ramis, dr_egon_spengler).
actor(ghost_busters, rick_moranis, louis_tully).
actress(ghost_busters, annie_potts, janine_melnitz).
actor(ghost_busters, william_atherton, walter_peck_wally_wick).
actor(ghost_busters, ernie_hudson, winston_zeddmore).
actor(ghost_busters, david_margulies, mayor).
actor(ghost_busters, steven_tash, male_student).
actress(ghost_busters, jennifer_runyon, female_student).
actress(ghost_busters, slavitza_jovan, gozer).
actor(ghost_busters, michael_ensign, hotel_manager).
actress(ghost_busters, alice_drummond, librarian).
actor(ghost_busters, jordan_charney, dean_yeager).
actor(ghost_busters, timothy_carhart, violinist).
actor(ghost_busters, john_rothman, library_administrator).
actor(ghost_busters, tom_mcdermott, archbishop).
actor(ghost_busters, roger_grimsby, himself).
actor(ghost_busters, larry_king, himself).
actor(ghost_busters, joe_franklin, himself).
actor(ghost_busters, casey_kasem, himself).
actor(ghost_busters, john_ring, fire_commissioner).
actor(ghost_busters, norman_matlock, police_commissioner).
actor(ghost_busters, joe_cirillo, police_captain).
actor(ghost_busters, joe_schmieg, police_seargeant).
actor(ghost_busters, reginald_veljohnson, jail_guard).
actress(ghost_busters, rhoda_gemignani, real_estate_woman).
actor(ghost_busters, murray_rubin, man_at_elevator).
actor(ghost_busters, larry_dilg, con_edison_man).
actor(ghost_busters, danny_stone, coachman).
actress(ghost_busters, patty_dworkin, woman_at_party).
actress(ghost_busters, jean_kasem, tall_woman_at_party).
actor(ghost_busters, lenny_del_genio, doorman).
actress(ghost_busters, frances_e_nealy, chambermaid).
actor(ghost_busters, sam_moses, hot_dog_vendor).
actor(ghost_busters, christopher_wynkoop, tv_reporter).
actor(ghost_busters, winston_may, businessman_in_cab).
actor(ghost_busters, tommy_hollis, mayor_s_aide).
actress(ghost_busters, eda_reiss_merin, louis_s_neighbor).
actor(ghost_busters, ric_mancini, policeman_at_apartment).
actress(ghost_busters, kathryn_janssen, mrs_van_hoffman).
actor(ghost_busters, stanley_grover, reporter).
actress(ghost_busters, carol_ann_henry, reporter).
actor(ghost_busters, james_hardie, reporter).
actress(ghost_busters, frances_turner, reporter).
actress(ghost_busters, nancy_kelly, reporter).
actor(ghost_busters, paul_trafas, ted_fleming).
actress(ghost_busters, cheryl_birchenfield, annette_fleming).
actress(ghost_busters, ruth_oliver, library_ghost).
actress(ghost_busters, kymberly_herrin, dream_ghost).
actor(ghost_busters, larry_bilzarian, prisoner).
actor(ghost_busters, matteo_cafiso, boy_at_hot_dog_stand).
actress(ghost_busters, paddi_edwards, gozer).
actress(ghost_busters, deborah_gibson, birthday_girl_in_tavern_on_the_green).
actor(ghost_busters, charles_levin, honeymooner).
actor(ghost_busters, joseph_marzano, man_in_taxi).
actor(ghost_busters, joe_medjuck, man_at_library).
actor(ghost_busters, frank_patton, city_hall_cop).
actor(ghost_busters, harrison_ray, terror_dog).
actor(ghost_busters, ivan_reitman, zuul_slimer).
actor(ghost_busters, mario_todisco, prisoner).
actor(ghost_busters, bill_walton, himself).

movie(girl_with_a_pearl_earring, 2003).
director(girl_with_a_pearl_earring, peter_webber).
actor(girl_with_a_pearl_earring, colin_firth, johannes_vermeer).
actress(girl_with_a_pearl_earring, scarlett_johansson, griet).
actor(girl_with_a_pearl_earring, tom_wilkinson, van_ruijven).
actress(girl_with_a_pearl_earring, judy_parfitt, maria_thins).
actor(girl_with_a_pearl_earring, cillian_murphy, pieter).
actress(girl_with_a_pearl_earring, essie_davis, catharina_vermeer).
actress(girl_with_a_pearl_earring, joanna_scanlan, tanneke).
actress(girl_with_a_pearl_earring, alakina_mann, cornelia_vermeer).
actor(girl_with_a_pearl_earring, chris_mchallem, griet_s_father).
actress(girl_with_a_pearl_earring, gabrielle_reidy, griet_s_mother).
actor(girl_with_a_pearl_earring, rollo_weeks, frans).
actress(girl_with_a_pearl_earring, anna_popplewell, maertge).
actress(girl_with_a_pearl_earring, ana_s_nepper, lisbeth).
actress(girl_with_a_pearl_earring, melanie_meyfroid, aleydis).
actor(girl_with_a_pearl_earring, nathan_nepper, johannes).
actress(girl_with_a_pearl_earring, lola_carpenter, baby_franciscus).
actress(girl_with_a_pearl_earring, charlotte_carpenter, baby_franciscus).
actress(girl_with_a_pearl_earring, olivia_chauveau, baby_franciscus).
actor(girl_with_a_pearl_earring, geoff_bell, paul_the_butcher).
actress(girl_with_a_pearl_earring, virginie_colin, emilie_van_ruijven).
actress(girl_with_a_pearl_earring, sarah_drews, van_ruijven_s_daughter).
actress(girl_with_a_pearl_earring, christelle_bulckaen, wet_nurse).
actor(girl_with_a_pearl_earring, john_mcenery, apothecary).
actress(girl_with_a_pearl_earring, gintare_parulyte, model).
actress(girl_with_a_pearl_earring, claire_johnston, white_haired_woman).
actor(girl_with_a_pearl_earring, marc_maes, old_gentleman).
actor(girl_with_a_pearl_earring, robert_sibenaler, priest).
actor(girl_with_a_pearl_earring, dustin_james, servant_1).
actor(girl_with_a_pearl_earring, joe_reavis, servant_2).
actor(girl_with_a_pearl_earring, martin_serene, sergeant).
actor(girl_with_a_pearl_earring, chris_kelly, gay_blade).
actor(girl_with_a_pearl_earring, leslie_woodhall, neighbour).

movie(the_godfather, 1972).
director(the_godfather, francis_ford_coppola).
actor(the_godfather, marlon_brando, don_vito_corleone).
actor(the_godfather, al_pacino, michael_corleone).
actor(the_godfather, james_caan, santino_sonny_corleone).
actor(the_godfather, richard_s_castellano, pete_clemenza).
actor(the_godfather, robert_duvall, tom_hagen).
actor(the_godfather, sterling_hayden, capt_mark_mccluskey).
actor(the_godfather, john_marley, jack_woltz).
actor(the_godfather, richard_conte, emilio_barzini).
actor(the_godfather, al_lettieri, virgil_sollozzo).
actress(the_godfather, diane_keaton, kay_adams).
actor(the_godfather, abe_vigoda, salvadore_sally_tessio).
actress(the_godfather, talia_shire, connie).
actor(the_godfather, gianni_russo, carlo_rizzi).
actor(the_godfather, john_cazale, fredo).
actor(the_godfather, rudy_bond, ottilio_cuneo).
actor(the_godfather, al_martino, johnny_fontane).
actress(the_godfather, morgana_king, mama_corleone).
actor(the_godfather, lenny_montana, luca_brasi).
actor(the_godfather, john_martino, paulie_gatto).
actor(the_godfather, salvatore_corsitto, amerigo_bonasera).
actor(the_godfather, richard_bright, al_neri).
actor(the_godfather, alex_rocco, moe_greene).
actor(the_godfather, tony_giorgio, bruno_tattaglia).
actor(the_godfather, vito_scotti, nazorine).
actress(the_godfather, tere_livrano, theresa_hagen).
actor(the_godfather, victor_rendina, philip_tattaglia).
actress(the_godfather, jeannie_linero, lucy_mancini).
actress(the_godfather, julie_gregg, sandra_corleone).
actress(the_godfather, ardell_sheridan, mrs_clemenza).
actress(the_godfather, simonetta_stefanelli, apollonia_vitelli_corleone).
actor(the_godfather, angelo_infanti, fabrizio).
actor(the_godfather, corrado_gaipa, don_tommasino).
actor(the_godfather, franco_citti, calo).
actor(the_godfather, saro_urz, vitelli).
actor(the_godfather, carmine_coppola, piano_player_in_montage_scene).
actor(the_godfather, gian_carlo_coppola, baptism_observer).
actress(the_godfather, sofia_coppola, michael_francis_rizzi).
actor(the_godfather, ron_gilbert, usher_in_bridal_party).
actor(the_godfather, anthony_gounaris, anthony_vito_corleone).
actor(the_godfather, joe_lo_grippo, sonny_s_bodyguard).
actor(the_godfather, sonny_grosso, cop_with_capt_mccluskey_outside_hospital).
actor(the_godfather, louis_guss, don_zaluchi_outspoken_don_at_the_peace_conference).
actor(the_godfather, randy_jurgensen, sonny_s_killer_1).
actor(the_godfather, tony_lip, wedding_guest).
actor(the_godfather, frank_macetta, '').
actor(the_godfather, lou_martini_jr, boy_at_wedding).
actor(the_godfather, father_joseph_medeglia, priest_at_baptism).
actor(the_godfather, rick_petrucelli, man_in_passenger_seat_when_michael_is_driven_to_the_hospital).
actor(the_godfather, burt_richards, floral_designer).
actor(the_godfather, sal_richards, drunk).
actor(the_godfather, tom_rosqui, rocco_lampone).
actor(the_godfather, frank_sivero, extra).
actress(the_godfather, filomena_spagnuolo, extra_at_wedding_scene).
actor(the_godfather, joe_spinell, willie_cicci).
actor(the_godfather, gabriele_torrei, enzo_robutti_the_baker).
actor(the_godfather, nick_vallelonga, wedding_party_guest).
actor(the_godfather, ed_vantura, wedding_guest).
actor(the_godfather, matthew_vlahakis, clemenza_s_son_pushing_toy_car_in_driveway).

movie(the_godfather_part_ii, 1974).
director(the_godfather_part_ii, francis_ford_coppola).
actor(the_godfather_part_ii, al_pacino, don_michael_corleone).
actor(the_godfather_part_ii, robert_duvall, tom_hagen).
actress(the_godfather_part_ii, diane_keaton, kay_corleone).
actor(the_godfather_part_ii, robert_de_niro, vito_corleone).
actor(the_godfather_part_ii, john_cazale, fredo_corleone).
actress(the_godfather_part_ii, talia_shire, connie_corleone).
actor(the_godfather_part_ii, lee_strasberg, hyman_roth).
actor(the_godfather_part_ii, michael_v_gazzo, frankie_pentangeli).
actor(the_godfather_part_ii, g_d_spradlin, sen_pat_geary).
actor(the_godfather_part_ii, richard_bright, al_neri).
actor(the_godfather_part_ii, gastone_moschin, don_fanucci).
actor(the_godfather_part_ii, tom_rosqui, rocco_lampone).
actor(the_godfather_part_ii, bruno_kirby, young_clemenza_peter).
actor(the_godfather_part_ii, frank_sivero, genco_abbandando).
actress(the_godfather_part_ii, francesca_de_sapio, young_mama_corleone).
actress(the_godfather_part_ii, morgana_king, older_carmella_mama_corleone).
actress(the_godfather_part_ii, marianna_hill, deanna_dunn_corleone).
actor(the_godfather_part_ii, leopoldo_trieste, signor_roberto_landlord).
actor(the_godfather_part_ii, dominic_chianese, johnny_ola).
actor(the_godfather_part_ii, amerigo_tot, busetta_michael_s_bodyguard).
actor(the_godfather_part_ii, troy_donahue, merle_johnson).
actor(the_godfather_part_ii, john_aprea, young_sal_tessio).
actor(the_godfather_part_ii, joe_spinell, willie_cicci).
actor(the_godfather_part_ii, james_caan, sonny_corleone_special_participation).
actor(the_godfather_part_ii, abe_vigoda, sal_tessio).
actress(the_godfather_part_ii, tere_livrano, theresa_hagen).
actor(the_godfather_part_ii, gianni_russo, carlo_rizzi).
actress(the_godfather_part_ii, maria_carta, signora_andolini_vito_s_mother).
actor(the_godfather_part_ii, oreste_baldini, young_vito_andolini).
actor(the_godfather_part_ii, giuseppe_sillato, don_francesco_ciccio).
actor(the_godfather_part_ii, mario_cotone, don_tommasino).
actor(the_godfather_part_ii, james_gounaris, anthony_vito_corleone).
actress(the_godfather_part_ii, fay_spain, mrs_marcia_roth).
actor(the_godfather_part_ii, harry_dean_stanton, fbi_man_1).
actor(the_godfather_part_ii, david_baker, fbi_man_2).
actor(the_godfather_part_ii, carmine_caridi, carmine_rosato).
actor(the_godfather_part_ii, danny_aiello, tony_rosato).
actor(the_godfather_part_ii, carmine_foresta, policeman).
actor(the_godfather_part_ii, nick_discenza, bartender).
actor(the_godfather_part_ii, father_joseph_medeglia, father_carmelo).
actor(the_godfather_part_ii, william_bowers, senate_committee_chairman).
actor(the_godfather_part_ii, joseph_della_sorte, michael_s_buttonman_1).
actor(the_godfather_part_ii, carmen_argenziano, michael_s_buttonman_2).
actor(the_godfather_part_ii, joe_lo_grippo, michael_s_buttonman_3).
actor(the_godfather_part_ii, ezio_flagello, impresario).
actor(the_godfather_part_ii, livio_giorgi, tenor_in_senza_mamma).
actress(the_godfather_part_ii, kathleen_beller, girl_in_senza_mamma).
actress(the_godfather_part_ii, saveria_mazzola, signora_colombo).
actor(the_godfather_part_ii, tito_alba, cuban_pres_fulgencio_batista).
actor(the_godfather_part_ii, johnny_naranjo, cuban_translator).
actress(the_godfather_part_ii, elda_maida, pentangeli_s_wife).
actor(the_godfather_part_ii, salvatore_po, vincenzo_pentangeli).
actor(the_godfather_part_ii, ignazio_pappalardo, mosca_assassin_in_sicily).
actor(the_godfather_part_ii, andrea_maugeri, strollo).
actor(the_godfather_part_ii, peter_lacorte, signor_abbandando).
actor(the_godfather_part_ii, vincent_coppola, street_vendor).
actor(the_godfather_part_ii, peter_donat, questadt).
actor(the_godfather_part_ii, tom_dahlgren, fred_corngold).
actor(the_godfather_part_ii, paul_b_brown, sen_ream).
actor(the_godfather_part_ii, phil_feldman, senator_1).
actor(the_godfather_part_ii, roger_corman, senator_2).
actress(the_godfather_part_ii, ivonne_coll, yolanda).
actor(the_godfather_part_ii, joe_de_nicola, attendant_at_brothel).
actor(the_godfather_part_ii, edward_van_sickle, ellis_island_doctor).
actress(the_godfather_part_ii, gabriella_belloni, ellis_island_nurse).
actor(the_godfather_part_ii, richard_watson, customs_official).
actress(the_godfather_part_ii, venancia_grangerard, cuban_nurse).
actress(the_godfather_part_ii, erica_yohn, governess).
actress(the_godfather_part_ii, theresa_tirelli, midwife).
actor(the_godfather_part_ii, roman_coppola, sonny_corleone_as_a_boy).
actress(the_godfather_part_ii, sofia_coppola, child_on_steamship_in_ny_harbor).
actor(the_godfather_part_ii, larry_guardino, vito_s_uncle).
actor(the_godfather_part_ii, gary_kurtz, photographer_in_court).
actress(the_godfather_part_ii, laura_lyons, '').
actress(the_godfather_part_ii, connie_mason, extra).
actor(the_godfather_part_ii, john_megna, young_hyman_roth).
actor(the_godfather_part_ii, frank_pesce, extra).
actress(the_godfather_part_ii, filomena_spagnuolo, extra_in_little_italy).
