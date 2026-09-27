$Data << EOD
tgamma 5472.6961 5683.6851 5629.1264 5588.6180 5499.0649 5381.0513 5270.6475 4869.5345
lgamma 5123.2334 5449.2285 5296.5095 5239.5172 5127.9933 5012.1264 4947.3400 4520.5278
EOD

# name mean p0 p10 p25 p50 p75 p90 p100

set title "zmida"
set ylabel "Kops/sec"
set grid y

set style fill solid 0.5 border
set boxwidth 0.6
set autoscale xfix
set offsets 0.5, 0.5, 0, 0
set xtics rotate by -45 scale 0

plot $Data using \
        0:7:4:8:5:xticlabels(1) \
        with candlesticks \
        linecolor rgb "#333333" \
        fill solid 0.4 \
        title "p25/p75", \
    $Data using 0:4:(0.12) \
        with xerrorbars pointtype 0 \
        linecolor rgb "#333333" \
        title "p10/p90", \
    $Data using 0:8:(0.12) \
        with xerrorbars pointtype 0 \
        linecolor rgb "#333333" \
        notitle, \
     $Data using \
        0:6:(0.3) \
        with xerrorbars \
        pointtype 0 \
        linecolor rgb "#333333" \
        title "p50", \
     $Data using \
        0:3 \
        with points \
        pointtype 7 pointsize 1.0 \
        linecolor rgb "#333333" \
        title "min", \
     $Data using \
        0:9 \
        with points \
        pointtype 7 pointsize 1.0 \
        linecolor rgb "#333333" \
        title "max", \
     $Data using \
        0:2 \
        with points \
        pointtype 7 pointsize 1.2 \
        linecolor rgb "#d62728" \
        title "mean"
