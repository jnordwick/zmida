$Data << EOD
ccall 1006440.8456 986293.4344 994535.0301 1009018.4438 1023001.4854 1032915.0598
vcall 721696.9855 662404.0636 713388.4376 725834.7161 748343.7547 760698.5455
vcall_dno 554174.0836 498339.5691 548148.7325 572638.3132 583661.4057 592822.4855
dcall 1336354.5372 1253352.1794 1327520.2854 1358025.3512 1384468.2650 1401862.6350
dcall_dno 995655.5696 947379.0645 991414.3016 1009468.0365 1022838.0354 1039416.4457
mcall 1021550.7905 997265.5583 1010348.4564 1022802.6880 1034637.8223 1047920.1916
EOD

# name mean p10 p25 p50 p75 p90

set title "zmida"
set ylabel "Kops/sec"
set grid y

set style fill solid 0.65 border
set boxwidth 0.6
set autoscale xfix
set offsets 0.5, 0.5, 0, 0
set xtics rotate by -30 scale 0

plot $Data using 0:4:3:7:6:xticlabels(1) with candlesticks \
        linecolor rgb "black" fillcolor "#7788aa" title "p10/25/75/90", \
    $Data using 0:5:(0.30) with xerrorbars linecolor "black" pointtype 0 title "median", \
    $Data using 0:2 with points pointtype 2 pointsize 1.3 linecolor rgb "#cc7033" title "mean"
 
