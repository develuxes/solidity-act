[Transition (AlexPn 444 17 1) "frob" "Vat" frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) [IffIn (AlexPn 546 20 1) uint256 [EAdd (AlexPn 587 22 20) (EUTEntry (EField (AlexPn 582 22 15) (EMapping (AlexPn 576 22 9) (EVar (AlexPn 572 22 5) "urns") [EUTEntry (EVar (AlexPn 577 22 10) "i"),EUTEntry (EVar (AlexPn 580 22 13) "u")]) "ink")) (EUTEntry (EVar (AlexPn 589 22 22) "dink")),EAdd (AlexPn 613 23 20) (EUTEntry (EField (AlexPn 608 23 15) (EMapping (AlexPn 602 23 9) (EVar (AlexPn 598 23 5) "urns") [EUTEntry (EVar (AlexPn 603 23 10) "i"),EUTEntry (EVar (AlexPn 606 23 13) "u")]) "art")) (EUTEntry (EVar (AlexPn 615 23 22) "dart")),EAdd (AlexPn 639 24 20) (EUTEntry (EField (AlexPn 631 24 12) (EMapping (AlexPn 628 24 9) (EVar (AlexPn 624 24 5) "ilks") [EUTEntry (EVar (AlexPn 629 24 10) "i")]) "Art")) (EUTEntry (EVar (AlexPn 641 24 22) "dart")),EMul (AlexPn 671 25 26) (EAdd (AlexPn 663 25 18) (EUTEntry (EField (AlexPn 658 25 13) (EMapping (AlexPn 655 25 10) (EVar (AlexPn 651 25 6) "ilks") [EUTEntry (EVar (AlexPn 656 25 11) "i")]) "Art")) (EUTEntry (EVar (AlexPn 665 25 20) "dart"))) (EUTEntry (EField (AlexPn 680 25 35) (EMapping (AlexPn 677 25 32) (EVar (AlexPn 673 25 28) "ilks") [EUTEntry (EVar (AlexPn 678 25 33) "i")]) "rate")),EAdd (AlexPn 697 26 12) (EUTEntry (EMapping (AlexPn 693 26 8) (EVar (AlexPn 690 26 5) "dai") [EUTEntry (EVar (AlexPn 694 26 9) "w")])) (EMul (AlexPn 713 26 28) (EUTEntry (EField (AlexPn 707 26 22) (EMapping (AlexPn 704 26 19) (EVar (AlexPn 700 26 15) "ilks") [EUTEntry (EVar (AlexPn 705 26 20) "i")]) "rate")) (EUTEntry (EVar (AlexPn 715 26 30) "dart"))),EAdd (AlexPn 730 27 10) (EUTEntry (EVar (AlexPn 725 27 5) "debt")) (EMul (AlexPn 746 27 26) (EUTEntry (EField (AlexPn 740 27 20) (EMapping (AlexPn 737 27 17) (EVar (AlexPn 733 27 13) "ilks") [EUTEntry (EVar (AlexPn 738 27 18) "i")]) "rate")) (EUTEntry (EVar (AlexPn 748 27 28) "dart")))],IffIn (AlexPn 755 29 1) int256 [EUTEntry (EField (AlexPn 787 31 12) (EMapping (AlexPn 784 31 9) (EVar (AlexPn 780 31 5) "ilks") [EUTEntry (EVar (AlexPn 785 31 10) "i")]) "rate"),EMul (AlexPn 810 32 18) (EUTEntry (EField (AlexPn 804 32 12) (EMapping (AlexPn 801 32 9) (EVar (AlexPn 797 32 5) "ilks") [EUTEntry (EVar (AlexPn 802 32 10) "i")]) "rate")) (EUTEntry (EVar (AlexPn 812 32 20) "dart"))],Iff (AlexPn 818 34 1) [EEq (AlexPn 836 35 15) (EnvExp (AlexPn 826 35 5) Callvalue) (IntLit (AlexPn 839 35 18) 0),EEq (AlexPn 850 36 10) (EUTEntry (EVar (AlexPn 845 36 5) "live")) (IntLit (AlexPn 853 36 13) 1),ENeq (AlexPn 872 37 18) (EUTEntry (EField (AlexPn 866 37 12) (EMapping (AlexPn 863 37 9) (EVar (AlexPn 859 37 5) "ilks") [EUTEntry (EVar (AlexPn 864 37 10) "i")]) "rate")) (IntLit (AlexPn 876 37 22) 0),EOr (AlexPn 892 38 15) (ELEQ (AlexPn 887 38 10) (EUTEntry (EVar (AlexPn 882 38 5) "dart")) (IntLit (AlexPn 890 38 13) 0)) (EAnd (AlexPn 948 38 71) (ELEQ (AlexPn 932 38 55) (EMul (AlexPn 917 38 40) (EAdd (AlexPn 909 38 32) (EUTEntry (EField (AlexPn 904 38 27) (EMapping (AlexPn 901 38 24) (EVar (AlexPn 897 38 20) "ilks") [EUTEntry (EVar (AlexPn 902 38 25) "i")]) "art")) (EUTEntry (EVar (AlexPn 911 38 34) "dart"))) (EUTEntry (EField (AlexPn 926 38 49) (EMapping (AlexPn 923 38 46) (EVar (AlexPn 919 38 42) "ilks") [EUTEntry (EVar (AlexPn 924 38 47) "i")]) "rate"))) (EUTEntry (EField (AlexPn 942 38 65) (EMapping (AlexPn 939 38 62) (EVar (AlexPn 935 38 58) "ilks") [EUTEntry (EVar (AlexPn 940 38 63) "i")]) "line"))) (ELEQ (AlexPn 979 38 102) (EAdd (AlexPn 957 38 80) (EUTEntry (EVar (AlexPn 952 38 75) "debt")) (EMul (AlexPn 972 38 95) (EUTEntry (EField (AlexPn 966 38 89) (EMapping (AlexPn 963 38 86) (EVar (AlexPn 959 38 82) "ilks") [EUTEntry (EVar (AlexPn 964 38 87) "i")]) "rate")) (EUTEntry (EVar (AlexPn 974 38 97) "dart")))) (EUTEntry (EVar (AlexPn 982 38 105) "line")))),EOr (AlexPn 1004 39 17) (ELEQ (AlexPn 998 39 11) (EUTEntry (EVar (AlexPn 993 39 6) "dart")) (IntLit (AlexPn 1001 39 14) 0)) (EAnd (AlexPn 1062 39 75) (ELEQ (AlexPn 1045 39 58) (EMul (AlexPn 1030 39 43) (EAdd (AlexPn 1022 39 35) (EUTEntry (EField (AlexPn 1017 39 30) (EMapping (AlexPn 1014 39 27) (EVar (AlexPn 1010 39 23) "ilks") [EUTEntry (EVar (AlexPn 1015 39 28) "i")]) "Art")) (EUTEntry (EVar (AlexPn 1024 39 37) "dart"))) (EUTEntry (EField (AlexPn 1039 39 52) (EMapping (AlexPn 1036 39 49) (EVar (AlexPn 1032 39 45) "ilks") [EUTEntry (EVar (AlexPn 1037 39 50) "i")]) "rate"))) (EUTEntry (EField (AlexPn 1055 39 68) (EMapping (AlexPn 1052 39 65) (EVar (AlexPn 1048 39 61) "ilks") [EUTEntry (EVar (AlexPn 1053 39 66) "i")]) "line"))) (ELEQ (AlexPn 1096 39 109) (EAdd (AlexPn 1073 39 86) (EUTEntry (EVar (AlexPn 1068 39 81) "debt")) (EMul (AlexPn 1088 39 101) (EUTEntry (EField (AlexPn 1082 39 95) (EMapping (AlexPn 1079 39 92) (EVar (AlexPn 1075 39 88) "ilks") [EUTEntry (EVar (AlexPn 1080 39 93) "i")]) "rate")) (EUTEntry (EVar (AlexPn 1090 39 103) "dart")))) (EUTEntry (EVar (AlexPn 1099 39 112) "line")))),EOr (AlexPn 1136 40 31) (EAnd (AlexPn 1121 40 16) (ELEQ (AlexPn 1116 40 11) (EUTEntry (EVar (AlexPn 1111 40 6) "dart")) (IntLit (AlexPn 1119 40 14) 0)) (EGEQ (AlexPn 1130 40 25) (EUTEntry (EVar (AlexPn 1125 40 20) "dink")) (IntLit (AlexPn 1133 40 28) 0))) (ELEQ (AlexPn 1181 40 76) (EMul (AlexPn 1165 40 60) (EAdd (AlexPn 1157 40 52) (EUTEntry (EField (AlexPn 1152 40 47) (EMapping (AlexPn 1146 40 41) (EVar (AlexPn 1142 40 37) "urns") [EUTEntry (EVar (AlexPn 1147 40 42) "i"),EUTEntry (EVar (AlexPn 1150 40 45) "u")]) "art")) (EUTEntry (EVar (AlexPn 1159 40 54) "dart"))) (EUTEntry (EField (AlexPn 1174 40 69) (EMapping (AlexPn 1171 40 66) (EVar (AlexPn 1167 40 62) "ilks") [EUTEntry (EVar (AlexPn 1172 40 67) "i")]) "rate"))) (EMul (AlexPn 1209 40 104) (EAdd (AlexPn 1201 40 96) (EUTEntry (EField (AlexPn 1196 40 91) (EMapping (AlexPn 1190 40 85) (EVar (AlexPn 1186 40 81) "urns") [EUTEntry (EVar (AlexPn 1191 40 86) "i"),EUTEntry (EVar (AlexPn 1194 40 89) "u")]) "ink")) (EUTEntry (EVar (AlexPn 1203 40 98) "dink"))) (EUTEntry (EField (AlexPn 1218 40 113) (EMapping (AlexPn 1215 40 110) (EVar (AlexPn 1211 40 106) "ilks") [EUTEntry (EVar (AlexPn 1216 40 111) "i")]) "spot")))),EOr (AlexPn 1256 41 31) (EAnd (AlexPn 1241 41 16) (ELEQ (AlexPn 1236 41 11) (EUTEntry (EVar (AlexPn 1231 41 6) "dart")) (IntLit (AlexPn 1239 41 14) 0)) (EGEQ (AlexPn 1250 41 25) (EUTEntry (EVar (AlexPn 1245 41 20) "dink")) (IntLit (AlexPn 1253 41 28) 0))) (EOr (AlexPn 1272 41 47) (EEq (AlexPn 1262 41 37) (EUTEntry (EVar (AlexPn 1260 41 35) "u")) (EnvExp (AlexPn 1265 41 40) Caller)) (EEq (AlexPn 1290 41 65) (EUTEntry (EMapping (AlexPn 1278 41 53) (EVar (AlexPn 1275 41 50) "can") [EUTEntry (EVar (AlexPn 1279 41 54) "u"),EnvExp (AlexPn 1282 41 57) Caller])) (IntLit (AlexPn 1293 41 68) 1))),EOr (AlexPn 1313 43 17) (ELEQ (AlexPn 1307 43 11) (EUTEntry (EVar (AlexPn 1302 43 6) "dink")) (IntLit (AlexPn 1310 43 14) 0)) (EOr (AlexPn 1329 43 33) (EEq (AlexPn 1319 43 23) (EUTEntry (EVar (AlexPn 1317 43 21) "v")) (EnvExp (AlexPn 1322 43 26) Caller)) (EEq (AlexPn 1347 43 51) (EUTEntry (EMapping (AlexPn 1335 43 39) (EVar (AlexPn 1332 43 36) "Can") [EUTEntry (EVar (AlexPn 1336 43 40) "v"),EnvExp (AlexPn 1339 43 43) Caller])) (IntLit (AlexPn 1350 43 54) 1))),EOr (AlexPn 1369 44 17) (EGEQ (AlexPn 1363 44 11) (EUTEntry (EVar (AlexPn 1358 44 6) "dart")) (IntLit (AlexPn 1366 44 14) 0)) (EOr (AlexPn 1385 44 33) (EEq (AlexPn 1375 44 23) (EUTEntry (EVar (AlexPn 1373 44 21) "w")) (EnvExp (AlexPn 1378 44 26) Caller)) (EEq (AlexPn 1403 44 51) (EUTEntry (EMapping (AlexPn 1391 44 39) (EVar (AlexPn 1388 44 36) "Can") [EUTEntry (EVar (AlexPn 1392 44 40) "w"),EnvExp (AlexPn 1395 44 43) Caller])) (IntLit (AlexPn 1406 44 54) 1)))]] (Direct (Post [Rewrite (EField (AlexPn 1433 48 15) (EMapping (AlexPn 1427 48 9) (EVar (AlexPn 1423 48 5) "urns") [EUTEntry (EVar (AlexPn 1428 48 10) "i"),EUTEntry (EVar (AlexPn 1431 48 13) "u")]) "ink") (EAdd (AlexPn 1456 48 38) (EUTEntry (EField (AlexPn 1451 48 33) (EMapping (AlexPn 1445 48 27) (EVar (AlexPn 1441 48 23) "urns") [EUTEntry (EVar (AlexPn 1446 48 28) "i"),EUTEntry (EVar (AlexPn 1449 48 31) "u")]) "ink")) (EUTEntry (EVar (AlexPn 1458 48 40) "dink"))),Rewrite (EField (AlexPn 1477 49 15) (EMapping (AlexPn 1471 49 9) (EVar (AlexPn 1467 49 5) "urns") [EUTEntry (EVar (AlexPn 1472 49 10) "i"),EUTEntry (EVar (AlexPn 1475 49 13) "u")]) "art") (EAdd (AlexPn 1500 49 38) (EUTEntry (EField (AlexPn 1495 49 33) (EMapping (AlexPn 1489 49 27) (EVar (AlexPn 1485 49 23) "urns") [EUTEntry (EVar (AlexPn 1490 49 28) "i"),EUTEntry (EVar (AlexPn 1493 49 31) "u")]) "art")) (EUTEntry (EVar (AlexPn 1502 49 40) "dart"))),Rewrite (EField (AlexPn 1518 50 12) (EMapping (AlexPn 1515 50 9) (EVar (AlexPn 1511 50 5) "ilks") [EUTEntry (EVar (AlexPn 1516 50 10) "i")]) "Art") (EAdd (AlexPn 1541 50 35) (EUTEntry (EField (AlexPn 1536 50 30) (EMapping (AlexPn 1533 50 27) (EVar (AlexPn 1529 50 23) "ilks") [EUTEntry (EVar (AlexPn 1534 50 28) "i")]) "Art")) (EUTEntry (EVar (AlexPn 1543 50 37) "dart"))),Rewrite (EMapping (AlexPn 1555 51 8) (EVar (AlexPn 1552 51 5) "gem") [EUTEntry (EVar (AlexPn 1556 51 9) "i"),EUTEntry (EVar (AlexPn 1559 51 12) "v")]) (ESub (AlexPn 1582 51 35) (EUTEntry (EMapping (AlexPn 1573 51 26) (EVar (AlexPn 1570 51 23) "gem") [EUTEntry (EVar (AlexPn 1574 51 27) "i"),EUTEntry (EVar (AlexPn 1577 51 30) "v")])) (EUTEntry (EVar (AlexPn 1584 51 37) "dink"))),Rewrite (EMapping (AlexPn 1596 52 8) (EVar (AlexPn 1593 52 5) "dai") [EUTEntry (EVar (AlexPn 1597 52 9) "w")]) (EAdd (AlexPn 1618 52 30) (EUTEntry (EMapping (AlexPn 1614 52 26) (EVar (AlexPn 1611 52 23) "dai") [EUTEntry (EVar (AlexPn 1615 52 27) "w")])) (EMul (AlexPn 1633 52 45) (EUTEntry (EField (AlexPn 1627 52 39) (EMapping (AlexPn 1624 52 36) (EVar (AlexPn 1620 52 32) "ilks") [EUTEntry (EVar (AlexPn 1625 52 37) "i")]) "rate")) (EUTEntry (EVar (AlexPn 1635 52 47) "dart")))),Rewrite (EVar (AlexPn 1644 53 5) "debt") (EAdd (AlexPn 1669 53 30) (EUTEntry (EVar (AlexPn 1662 53 23) "debt")) (EMul (AlexPn 1684 53 45) (EUTEntry (EField (AlexPn 1678 53 39) (EMapping (AlexPn 1675 53 36) (EVar (AlexPn 1671 53 32) "ilks") [EUTEntry (EVar (AlexPn 1676 53 37) "i")]) "rate")) (EUTEntry (EVar (AlexPn 1686 53 47) "dart"))))] Nothing)) []]
