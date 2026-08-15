# Target Images Detailed Diagnostic Trace

## KakaoTalk_20260815_154947878_02.jpg (199x181)
**Issue Description**: Checklist #1/#2: Missing bus/load candidate

- **Final Pipeline Output**: Total 13 nodes, 19 lines
  - Counts: {'generator': 4, 'load': 3, 'bus': 6}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 49 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `generator` | 0.961 | 0.52 | [175.4, 74.8, 196.4, 95.1] | 21.0x20.3 | True | True | False | True | Kept |
| 1 | `generator` | 0.952 | 0.52 | [136.0, 0.3, 156.4, 20.1] | 20.4x19.8 | True | True | False | True | Kept |
| 2 | `load` | 0.942 | 0.35 | [141.2, 152.9, 152.5, 162.5] | 11.3x9.6 | True | True | False | False | Kept |
| 3 | `generator` | 0.934 | 0.52 | [3.7, 75.3, 24.5, 94.4] | 20.8x19.0 | True | True | False | True | Kept |
| 4 | `load` | 0.916 | 0.35 | [44.3, 152.7, 56.2, 162.5] | 11.9x9.8 | True | True | False | False | Kept |
| 5 | `generator` | 0.910 | 0.52 | [80.1, 152.8, 101.3, 173.4] | 21.2x20.6 | True | True | False | True | Kept |
| 6 | `load` | 0.852 | 0.35 | [44.5, 11.4, 55.4, 21.3] | 10.9x10.0 | True | True | False | False | Kept |
| 7 | `bus` | 0.761 | 0.30 | [73.3, 136.4, 108.7, 143.0] | 35.4x6.6 | True | False | False | False | Kept |
| 8 | `bus` | 0.743 | 0.30 | [128.3, 135.0, 164.5, 141.3] | 36.2x6.3 | True | False | False | False | Kept |
| 9 | `bus` | 0.726 | 0.30 | [32.5, 135.0, 75.1, 141.5] | 42.5x6.5 | True | False | False | False | Kept |
| 10 | `bus` | 0.709 | 0.30 | [158.1, 68.4, 163.9, 101.9] | 5.7x33.6 | True | False | False | False | Kept |
| 11 | `bus` | 0.658 | 0.30 | [129.3, 31.9, 163.9, 37.6] | 34.6x5.7 | True | False | False | False | Kept |
| 12 | `bus` | 0.651 | 0.30 | [33.1, 31.9, 67.7, 38.0] | 34.5x6.1 | True | False | False | False | Kept |
| 13 | `bus` | 0.387 | 0.30 | [33.3, 68.3, 40.0, 101.4] | 6.7x33.1 | True | False | False | False | Kept |
| 14 | `generator` | 0.169 | 0.52 | [14.9, 73.9, 26.9, 95.6] | 12.1x21.7 | True | False | False | True | Dropped: conf 0.17 < thresh 0.52 |
| 15 | `bus` | 0.167 | 0.30 | [7.8, -283.0, 740.0, -126.1] | 732.2x156.9 | False | False | False | False | Dropped: conf 0.17 < thresh 0.30 |
| 16 | `bus` | 0.158 | 0.30 | [-540.0, -283.0, 267.4, -129.0] | 807.4x154.1 | False | False | False | False | Dropped: conf 0.16 < thresh 0.30 |
| 17 | `bus` | 0.157 | 0.30 | [71.6, -218.8, 740.0, -63.4] | 668.4x155.4 | False | False | False | False | Dropped: conf 0.16 < thresh 0.30 |
| 18 | `bus` | 0.151 | 0.30 | [71.9, -122.9, 740.0, 31.0] | 668.1x153.8 | False | False | True | False | Dropped: conf 0.15 < thresh 0.30 |
| 19 | `bus` | 0.146 | 0.30 | [72.1, -26.9, 740.0, 125.3] | 667.9x152.2 | True | False | True | False | Dropped: conf 0.15 < thresh 0.30 |
| 20 | `bus` | 0.146 | 0.30 | [7.8, -346.8, 740.0, -196.9] | 732.2x149.9 | False | False | False | False | Dropped: conf 0.15 < thresh 0.30 |
| 21 | `bus` | 0.144 | 0.30 | [72.1, 69.1, 740.0, 220.7] | 667.9x151.6 | False | False | True | False | Dropped: conf 0.14 < thresh 0.30 |
| 22 | `bus` | 0.144 | 0.30 | [72.1, 165.1, 740.0, 316.6] | 667.9x151.5 | False | False | True | False | Dropped: conf 0.14 < thresh 0.30 |
| 23 | `bus` | 0.144 | 0.30 | [72.1, 261.1, 740.0, 412.6] | 667.9x151.5 | False | False | False | False | Dropped: conf 0.14 < thresh 0.30 |
| 24 | `bus` | 0.142 | 0.30 | [-540.0, -346.8, 299.5, -197.3] | 839.5x149.5 | False | False | False | False | Dropped: conf 0.14 < thresh 0.30 |
| 25 | `bus` | 0.140 | 0.30 | [72.0, 357.2, 740.0, 510.4] | 668.0x153.2 | False | False | False | False | Dropped: conf 0.14 < thresh 0.30 |
| 26 | `bus` | 0.140 | 0.30 | [-376.0, -315.0, 555.2, -157.3] | 931.2x157.6 | False | False | False | False | Dropped: conf 0.14 < thresh 0.30 |
| 27 | `bus` | 0.134 | 0.30 | [-540.0, -186.9, 235.0, -38.3] | 775.0x148.6 | False | False | False | False | Dropped: conf 0.13 < thresh 0.30 |
| 28 | `bus` | 0.127 | 0.30 | [40.5, 421.1, 740.0, 577.2] | 699.5x156.2 | False | False | False | False | Dropped: conf 0.13 < thresh 0.30 |
| 29 | `bus` | 0.125 | 0.30 | [-540.0, -122.5, 234.9, 24.8] | 774.9x147.3 | False | False | False | False | Dropped: conf 0.12 < thresh 0.30 |
| 30 | `bus` | 0.120 | 0.30 | [-540.0, 421.3, 266.7, 577.0] | 806.7x155.7 | False | False | False | False | Dropped: conf 0.12 < thresh 0.30 |
| 31 | `bus` | 0.117 | 0.30 | [-540.0, 357.6, 234.7, 509.8] | 774.7x152.2 | False | False | False | False | Dropped: conf 0.12 < thresh 0.30 |
| 32 | `bus` | 0.117 | 0.30 | [-540.0, -58.8, 202.7, 83.3] | 742.7x142.0 | False | False | True | False | Dropped: conf 0.12 < thresh 0.30 |
| 33 | `bus` | 0.114 | 0.30 | [-540.0, 5.4, 202.7, 146.9] | 742.7x141.5 | False | False | True | False | Dropped: conf 0.11 < thresh 0.30 |
| 34 | `bus` | 0.112 | 0.30 | [-540.0, 293.5, 202.6, 439.2] | 742.6x145.7 | False | False | False | False | Dropped: conf 0.11 < thresh 0.30 |
| 35 | `bus` | 0.111 | 0.30 | [-540.0, 69.5, 202.7, 210.8] | 742.7x141.3 | False | False | True | False | Dropped: conf 0.11 < thresh 0.30 |
| 36 | `bus` | 0.111 | 0.30 | [-407.6, -378.7, 523.4, -237.7] | 931.0x141.0 | False | False | False | False | Dropped: conf 0.11 < thresh 0.30 |
| 37 | `bus` | 0.110 | 0.30 | [-540.0, 133.5, 202.7, 274.7] | 742.7x141.2 | False | False | True | False | Dropped: conf 0.11 < thresh 0.30 |
| 38 | `bus` | 0.109 | 0.30 | [-540.0, 229.6, 202.6, 372.6] | 742.6x143.0 | False | False | False | False | Dropped: conf 0.11 < thresh 0.30 |
| 39 | `bus` | 0.108 | 0.30 | [-375.1, 453.1, 554.8, 608.9] | 929.9x155.8 | False | False | False | False | Dropped: conf 0.11 < thresh 0.30 |
| 40 | `bus` | 0.099 | 0.30 | [-117.3, 485.1, 740.0, 644.9] | 857.3x159.8 | False | False | False | False | Dropped: conf 0.10 < thresh 0.30 |
| 41 | `bus` | 0.086 | 0.30 | [-437.1, -250.9, 489.8, -81.1] | 926.9x169.8 | False | False | False | False | Dropped: conf 0.09 < thresh 0.30 |
| 42 | `bus` | 0.084 | 0.30 | [-22.5, -410.5, 740.0, -281.0] | 762.5x129.5 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 43 | `bus` | 0.083 | 0.30 | [-540.0, -410.5, 299.0, -280.9] | 839.0x129.6 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 44 | `bus` | 0.080 | 0.30 | [-465.3, 517.1, 457.4, 677.1] | 922.7x160.1 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 45 | `bus` | 0.076 | 0.30 | [-540.0, 484.9, 201.4, 635.2] | 741.4x150.3 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 46 | `bus` | 0.057 | 0.30 | [-169.8, 549.2, 740.0, 708.9] | 909.8x159.8 | False | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 47 | `bus` | 0.053 | 0.30 | [-373.9, 389.9, 554.9, 498.9] | 928.8x109.1 | False | False | False | False | Dropped: conf 0.05 < thresh 0.30 |
| 48 | `bus` | 0.051 | 0.30 | [175.1, 517.9, 740.0, 668.3] | 564.9x150.4 | False | False | False | False | Dropped: conf 0.05 < thresh 0.30 |

## KakaoTalk_20260815_154947878_06.jpg (547x721)
**Issue Description**: Checklist #3-#6, #8, #9: Missing bus & loads

- **Final Pipeline Output**: Total 43 nodes, 81 lines
  - Counts: {'transformer': 3, 'generator': 10, 'load': 9, 'bus': 21}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 73 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `transformer` | 0.982 | 0.50 | [61.3, 420.0, 119.9, 442.3] | 58.6x22.3 | True | True | True | False | Kept |
| 1 | `generator` | 0.968 | 0.52 | [71.2, 23.7, 97.3, 49.4] | 26.1x25.7 | True | True | False | True | Kept |
| 2 | `generator` | 0.966 | 0.52 | [61.8, 248.2, 89.0, 273.9] | 27.2x25.6 | True | True | False | True | Kept |
| 3 | `generator` | 0.962 | 0.52 | [467.6, 145.3, 493.6, 170.3] | 26.0x25.1 | True | True | False | True | Kept |
| 4 | `generator` | 0.962 | 0.52 | [142.4, 676.7, 170.1, 703.0] | 27.6x26.3 | True | True | False | True | Kept |
| 5 | `generator` | 0.961 | 0.52 | [359.3, 38.1, 386.2, 64.4] | 26.9x26.3 | True | True | False | True | Kept |
| 6 | `transformer` | 0.958 | 0.50 | [244.3, 419.8, 304.4, 444.2] | 60.1x24.4 | False | True | True | False | Vetoed: numeric text & no wire contact |
| 7 | `generator` | 0.958 | 0.52 | [510.5, 277.9, 537.8, 303.9] | 27.2x26.0 | True | True | False | True | Kept |
| 8 | `generator` | 0.947 | 0.52 | [266.7, 676.4, 293.9, 702.2] | 27.3x25.8 | True | True | False | True | Kept |
| 9 | `transformer` | 0.945 | 0.50 | [332.3, 420.9, 391.6, 441.0] | 59.3x20.0 | False | True | True | False | Vetoed: numeric text & no wire contact |
| 10 | `generator` | 0.940 | 0.52 | [86.2, 341.3, 112.4, 366.2] | 26.2x24.9 | True | True | False | True | Kept |
| 11 | `generator` | 0.937 | 0.52 | [236.0, 38.8, 262.3, 65.1] | 26.3x26.3 | True | True | False | True | Kept |
| 12 | `generator` | 0.925 | 0.52 | [388.2, 677.6, 414.7, 703.3] | 26.5x25.7 | True | True | False | True | Kept |
| 13 | `load` | 0.849 | 0.35 | [181.9, 688.3, 199.3, 699.2] | 17.4x10.8 | True | True | False | False | Kept |
| 14 | `load` | 0.847 | 0.35 | [358.1, 243.4, 372.8, 252.9] | 14.7x9.5 | True | True | False | False | Kept |
| 15 | `load` | 0.828 | 0.35 | [248.5, 250.2, 265.1, 260.4] | 16.6x10.2 | True | True | False | False | Kept |
| 16 | `bus` | 0.716 | 0.30 | [251.5, 503.9, 296.5, 513.5] | 45.0x9.5 | True | False | False | False | Kept |
| 17 | `load` | 0.623 | 0.35 | [175.9, 295.6, 185.5, 310.2] | 9.6x14.6 | True | True | False | False | Kept |
| 18 | `bus` | 0.618 | 0.30 | [342.4, 382.9, 387.5, 392.4] | 45.1x9.6 | False | False | False | False | Kept |
| 19 | `load` | 0.606 | 0.35 | [122.2, 347.7, 137.3, 357.2] | 15.2x9.4 | False | True | False | False | Vetoed: numeric text & no wire contact |
| 20 | `bus` | 0.605 | 0.30 | [69.8, 383.5, 106.7, 392.4] | 36.9x8.9 | False | False | False | False | Kept |
| 21 | `bus` | 0.586 | 0.30 | [258.6, 647.5, 332.1, 655.1] | 73.4x7.7 | True | False | False | False | Kept |
| 22 | `bus` | 0.535 | 0.30 | [336.5, 505.0, 387.1, 513.9] | 50.6x8.8 | True | False | False | False | Kept |
| 23 | `bus` | 0.505 | 0.30 | [72.4, 504.1, 117.3, 514.2] | 44.9x10.1 | False | False | False | False | Kept |
| 24 | `bus` | 0.505 | 0.30 | [249.9, 382.8, 294.1, 392.5] | 44.2x9.8 | False | False | False | False | Kept |
| 25 | `bus` | 0.487 | 0.30 | [215.9, 86.1, 286.3, 93.1] | 70.4x6.9 | True | False | False | False | Kept |
| 26 | `load` | 0.480 | 0.35 | [300.5, 688.2, 317.3, 698.0] | 16.7x9.8 | True | True | False | False | Kept |
| 27 | `load` | 0.479 | 0.35 | [98.3, 463.3, 113.5, 472.8] | 15.2x9.4 | True | True | False | False | Kept |
| 28 | `bus` | 0.472 | 0.30 | [438.4, 147.3, 446.7, 197.1] | 8.3x49.8 | True | False | False | False | Kept |
| 29 | `bus` | 0.464 | 0.30 | [70.2, 312.4, 133.8, 319.2] | 63.7x6.8 | False | False | False | False | Kept |
| 30 | `bus` | 0.451 | 0.30 | [138.7, 647.3, 211.7, 655.5] | 72.9x8.2 | True | False | False | False | Kept |
| 31 | `bus` | 0.409 | 0.30 | [371.3, 647.6, 431.4, 654.7] | 60.1x7.1 | True | False | False | False | Kept |
| 32 | `bus` | 0.408 | 0.30 | [292.1, 565.0, 300.4, 617.5] | 8.3x52.4 | True | False | False | False | Kept |
| 33 | `load` | 0.399 | 0.35 | [515.4, 586.5, 526.0, 602.1] | 10.6x15.6 | True | True | False | False | Kept |
| 34 | `load` | 0.396 | 0.35 | [68.0, 183.5, 83.5, 194.0] | 15.5x10.5 | True | True | False | False | Kept |
| 35 | `bus` | 0.391 | 0.30 | [207.2, 287.9, 214.8, 338.4] | 7.7x50.6 | False | False | False | False | Kept |
| 36 | `bus` | 0.383 | 0.30 | [226.5, 216.8, 289.1, 223.0] | 62.7x6.2 | False | False | False | False | Kept |
| 37 | `bus` | 0.376 | 0.30 | [333.6, 214.1, 397.8, 221.0] | 64.2x6.9 | False | False | False | False | Kept |
| 38 | `bus` | 0.367 | 0.30 | [481.9, 277.4, 489.6, 327.3] | 7.8x49.9 | True | False | False | False | Kept |
| 39 | `bus` | 0.354 | 0.30 | [347.4, 85.9, 396.3, 93.1] | 48.9x7.2 | True | False | False | False | Kept |
| 40 | `load` | 0.344 | 0.35 | [-80.3, -32.4, 338.8, 542.4] | 419.1x574.8 | True | False | True | False | Dropped: conf 0.34 < thresh 0.35 |
| 41 | `bus` | 0.336 | 0.30 | [149.6, 546.7, 157.7, 596.6] | 8.1x49.9 | False | False | False | False | Kept |
| 42 | `bus` | 0.330 | 0.30 | [74.5, 68.8, 126.4, 76.5] | 51.9x7.7 | False | False | False | False | Kept |
| 43 | `load` | 0.320 | 0.35 | [516.0, 522.4, 526.4, 536.7] | 10.4x14.3 | True | True | False | False | Dropped: conf 0.32 < thresh 0.35 |
| 44 | `load` | 0.314 | 0.35 | [253.5, 570.3, 262.9, 585.7] | 9.4x15.5 | True | True | False | False | Dropped: conf 0.31 < thresh 0.35 |
| 45 | `load` | 0.308 | 0.35 | [354.8, 466.4, 370.7, 476.3] | 15.9x9.9 | True | True | False | False | Dropped: conf 0.31 < thresh 0.35 |
| 46 | `bus` | 0.300 | 0.30 | [479.8, 500.9, 488.7, 551.1] | 8.9x50.2 | False | False | False | False | Dropped: conf 0.30 < thresh 0.30 |
| 47 | `load` | 0.289 | 0.35 | [104.0, 28.8, 119.0, 38.4] | 15.0x9.6 | True | True | False | False | Dropped: conf 0.29 < thresh 0.35 |
| 48 | `bus` | 0.283 | 0.30 | [62.8, 214.3, 126.7, 221.0] | 63.9x6.7 | False | False | False | False | Dropped: conf 0.28 < thresh 0.30 |
| 49 | `load` | 0.275 | 0.35 | [521.7, 311.8, 531.9, 325.6] | 10.2x13.8 | False | True | False | False | Dropped: conf 0.27 < thresh 0.35 |
| 50 | `load` | 0.263 | 0.35 | [267.7, 463.5, 281.0, 472.7] | 13.4x9.1 | True | True | False | False | Dropped: conf 0.26 < thresh 0.35 |
| 51 | `bus` | 0.249 | 0.30 | [35.4, -109.8, 204.6, 225.4] | 169.2x335.2 | False | False | True | False | Dropped: conf 0.25 < thresh 0.30 |
| 52 | `bus` | 0.225 | 0.30 | [480.0, 572.2, 488.7, 623.0] | 8.7x50.8 | False | False | False | False | Dropped: conf 0.22 < thresh 0.30 |
| 53 | `load` | 0.168 | 0.35 | [-36.4, -89.1, 524.3, 251.9] | 560.6x341.0 | False | False | True | False | Dropped: conf 0.17 < thresh 0.35 |
| 54 | `load` | 0.159 | 0.35 | [189.9, 562.9, 199.1, 577.2] | 9.2x14.4 | True | True | False | False | Dropped: conf 0.16 < thresh 0.35 |
| 55 | `bus` | 0.140 | 0.30 | [-83.9, -116.3, 357.2, 414.4] | 441.1x530.7 | True | False | True | False | Dropped: conf 0.14 < thresh 0.30 |
| 56 | `bus` | 0.122 | 0.30 | [2.1, 110.6, 10.3, 160.4] | 8.2x49.9 | True | False | False | False | Dropped: conf 0.12 < thresh 0.30 |
| 57 | `bus` | 0.116 | 0.30 | [279.7, -44.7, 914.0, 103.4] | 634.3x148.1 | False | False | True | False | Dropped: conf 0.12 < thresh 0.30 |
| 58 | `bus` | 0.108 | 0.30 | [311.8, 19.5, 914.0, 161.8] | 602.2x142.4 | False | False | True | False | Dropped: conf 0.11 < thresh 0.30 |
| 59 | `bus` | 0.095 | 0.30 | [247.4, -108.5, 914.0, 31.0] | 666.6x139.5 | False | False | False | False | Dropped: conf 0.09 < thresh 0.30 |
| 60 | `bus` | 0.094 | 0.30 | [314.7, 83.5, 914.0, 224.9] | 599.3x141.4 | False | False | True | False | Dropped: conf 0.09 < thresh 0.30 |
| 61 | `bus` | 0.078 | 0.30 | [345.5, 147.9, 914.0, 283.1] | 568.5x135.2 | False | False | True | False | Dropped: conf 0.08 < thresh 0.30 |
| 62 | `bus` | 0.071 | 0.30 | [346.0, 596.0, 914.0, 724.3] | 568.0x128.3 | False | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 63 | `bus` | 0.070 | 0.30 | [347.8, 211.9, 914.0, 340.5] | 566.2x128.6 | False | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 64 | `bus` | 0.070 | 0.30 | [346.8, 532.0, 914.0, 658.2] | 567.2x126.2 | True | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 65 | `bus` | 0.069 | 0.30 | [347.7, 468.0, 914.0, 594.4] | 566.3x126.4 | False | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 66 | `bus` | 0.069 | 0.30 | [345.9, 659.9, 914.0, 791.1] | 568.1x131.1 | False | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 67 | `bus` | 0.069 | 0.30 | [348.6, 404.0, 914.0, 530.7] | 565.4x126.7 | False | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 68 | `bus` | 0.068 | 0.30 | [348.9, 340.0, 914.0, 466.6] | 565.1x126.6 | False | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 69 | `bus` | 0.068 | 0.30 | [348.7, 276.0, 914.0, 402.3] | 565.3x126.4 | True | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 70 | `load` | 0.065 | 0.35 | [-212.2, -32.1, 98.9, 462.1] | 311.1x494.3 | True | False | True | False | Dropped: conf 0.06 < thresh 0.35 |
| 71 | `bus` | 0.059 | 0.30 | [347.7, 723.9, 914.0, 859.4] | 566.3x135.6 | False | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 72 | `load` | 0.058 | 0.35 | [-101.1, -114.4, 87.8, 322.2] | 188.8x436.5 | False | False | True | False | Dropped: conf 0.06 < thresh 0.35 |

## KakaoTalk_20260815_154947878_08.jpg (1251x972)
**Issue Description**: Checklist #7, #10/#11: Missing buses, load, transformer

- **Final Pipeline Output**: Total 32 nodes, 36 lines
  - Counts: {'generator': 6, 'load': 12, 'bus': 14}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 54 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `generator` | 0.923 | 0.52 | [967.5, 164.5, 1024.7, 218.6] | 57.2x54.1 | False | True | False | True | Vetoed: numeric text & no wire contact |
| 1 | `load` | 0.905 | 0.35 | [762.3, 93.4, 783.6, 113.7] | 21.3x20.3 | True | True | False | False | Kept |
| 2 | `bus` | 0.903 | 0.30 | [928.5, 452.2, 1035.1, 462.7] | 106.6x10.4 | True | False | False | False | Kept |
| 3 | `bus` | 0.899 | 0.30 | [383.8, 607.5, 492.3, 617.9] | 108.5x10.4 | True | False | False | False | Kept |
| 4 | `bus` | 0.894 | 0.30 | [824.3, 762.5, 931.9, 773.5] | 107.6x11.0 | False | False | False | False | Kept |
| 5 | `load` | 0.893 | 0.35 | [331.6, 548.7, 352.6, 569.4] | 21.0x20.6 | True | True | False | False | Kept |
| 6 | `load` | 0.892 | 0.35 | [46.4, 859.5, 68.4, 882.3] | 22.0x22.8 | True | True | False | False | Kept |
| 7 | `bus` | 0.880 | 0.30 | [175.2, 141.3, 281.7, 151.1] | 106.5x9.8 | False | False | False | False | Kept |
| 8 | `bus` | 0.876 | 0.30 | [694.4, 142.5, 799.6, 151.5] | 105.2x8.9 | False | False | False | False | Kept |
| 9 | `bus` | 0.874 | 0.30 | [-1.3, 479.1, 101.4, 488.2] | 102.6x9.1 | False | False | False | False | Kept |
| 10 | `generator` | 0.870 | 0.52 | [253.7, 429.6, 309.0, 485.0] | 55.3x55.5 | True | True | False | True | Kept |
| 11 | `load` | 0.864 | 0.35 | [632.8, 197.6, 653.9, 217.2] | 21.1x19.7 | True | True | False | False | Kept |
| 12 | `generator` | 0.862 | 0.52 | [19.4, 366.2, 75.8, 422.6] | 56.4x56.4 | True | True | False | True | Kept |
| 13 | `load` | 0.858 | 0.35 | [1064.5, 291.8, 1085.0, 311.4] | 20.4x19.6 | True | True | False | False | Kept |
| 14 | `load` | 0.853 | 0.35 | [192.3, 93.4, 213.9, 113.9] | 21.6x20.5 | True | True | False | False | Kept |
| 15 | `bus` | 0.847 | 0.30 | [383.8, 64.0, 490.9, 73.7] | 107.1x9.7 | True | False | False | False | Kept |
| 16 | `load` | 0.845 | 0.35 | [424.7, 15.6, 448.2, 37.0] | 23.5x21.4 | True | True | False | False | Kept |
| 17 | `generator` | 0.844 | 0.52 | [1186.3, 378.4, 1241.1, 432.7] | 54.8x54.2 | True | True | False | True | Kept |
| 18 | `load` | 0.839 | 0.35 | [1037.8, 601.5, 1060.6, 623.2] | 22.7x21.7 | True | True | False | False | Kept |
| 19 | `bus` | 0.836 | 0.30 | [616.5, 245.2, 697.5, 255.8] | 81.0x10.6 | False | False | False | False | Kept |
| 20 | `generator` | 0.829 | 0.52 | [149.6, 895.8, 206.0, 951.1] | 56.4x55.3 | True | True | False | True | Kept |
| 21 | `load` | 0.827 | 0.35 | [503.5, 145.2, 524.5, 166.2] | 21.0x21.0 | True | True | False | False | Kept |
| 22 | `load` | 0.822 | 0.35 | [571.2, 368.7, 593.4, 389.9] | 22.2x21.2 | True | True | False | False | Kept |
| 23 | `bus` | 0.804 | 0.30 | [486.8, 193.8, 568.1, 203.5] | 81.3x9.7 | False | False | False | False | Kept |
| 24 | `load` | 0.804 | 0.35 | [985.0, 808.3, 1007.5, 830.7] | 22.6x22.4 | True | True | False | False | Kept |
| 25 | `generator` | 0.788 | 0.52 | [823.2, 844.4, 878.9, 898.1] | 55.8x53.7 | True | True | False | True | Kept |
| 26 | `bus` | 0.746 | 0.30 | [1105.2, 379.4, 1115.2, 432.0] | 10.0x52.5 | True | False | False | False | Kept |
| 27 | `bus` | 0.732 | 0.30 | [71.3, 814.7, 236.6, 825.3] | 165.3x10.7 | True | False | False | False | Kept |
| 28 | `bus` | 0.725 | 0.30 | [796.9, 556.4, 975.3, 565.2] | 178.4x8.8 | True | False | False | False | Kept |
| 29 | `bus` | 0.711 | 0.30 | [822.3, 348.7, 988.9, 358.7] | 166.6x10.0 | True | False | False | False | Kept |
| 30 | `load` | 0.467 | 0.35 | [1047.1, 461.4, 1063.7, 491.8] | 16.7x30.4 | False | True | False | False | Vetoed: numeric text & no wire contact |
| 31 | `bus` | 0.449 | 0.30 | [332.3, 400.6, 493.2, 410.3] | 160.9x9.7 | True | False | False | False | Kept |
| 32 | `load` | 0.447 | 0.35 | [825.0, 108.8, 845.1, 136.0] | 20.1x27.3 | False | True | False | False | Vetoed: numeric text & no wire contact |
| 33 | `transformer` | 0.392 | 0.50 | [397.1, 488.7, 466.0, 522.1] | 69.0x33.4 | False | False | True | False | Dropped: conf 0.39 < thresh 0.50 |
| 34 | `transformer` | 0.240 | 0.50 | [455.8, 469.2, 478.3, 523.0] | 22.4x53.8 | True | True | True | False | Dropped: conf 0.24 < thresh 0.50 |
| 35 | `bus` | 0.236 | 0.30 | [679.9, 212.0, 689.5, 238.5] | 9.6x26.5 | False | False | False | False | Dropped: conf 0.24 < thresh 0.30 |
| 36 | `bus` | 0.198 | 0.30 | [410.4, 400.5, 542.8, 410.4] | 132.4x9.9 | True | False | False | False | Dropped: conf 0.20 < thresh 0.30 |
| 37 | `bus` | 0.172 | 0.30 | [167.8, 814.8, 283.7, 825.4] | 115.9x10.6 | True | False | False | False | Dropped: conf 0.17 < thresh 0.30 |
| 38 | `bus` | 0.157 | 0.30 | [937.9, 349.6, 1034.9, 359.3] | 97.0x9.7 | True | False | False | False | Dropped: conf 0.16 < thresh 0.30 |
| 39 | `load` | 0.136 | 0.35 | [679.8, 212.0, 693.1, 235.5] | 13.2x23.5 | False | True | False | False | Dropped: conf 0.14 < thresh 0.35 |
| 40 | `load` | 0.128 | 0.35 | [695.8, 210.5, 716.4, 239.2] | 20.6x28.8 | False | True | True | False | Dropped: conf 0.13 < thresh 0.35 |
| 41 | `load` | 0.127 | 0.35 | [323.3, 805.1, 341.9, 823.9] | 18.6x18.8 | True | True | False | False | Dropped: conf 0.13 < thresh 0.35 |
| 42 | `load` | 0.116 | 0.35 | [264.5, 80.8, 276.8, 109.0] | 12.3x28.1 | False | True | False | False | Dropped: conf 0.12 < thresh 0.35 |
| 43 | `bus` | 0.110 | 0.30 | [920.4, 556.5, 1011.1, 566.3] | 90.7x9.8 | True | False | False | False | Dropped: conf 0.11 < thresh 0.30 |
| 44 | `bus` | 0.087 | 0.30 | [1200.9, 135.0, 1206.1, 247.4] | 5.2x112.4 | False | False | False | False | Dropped: conf 0.09 < thresh 0.30 |
| 45 | `load` | 0.086 | 0.35 | [282.7, 80.0, 299.6, 97.9] | 16.8x17.9 | True | True | False | False | Dropped: conf 0.09 < thresh 0.35 |
| 46 | `load` | 0.080 | 0.35 | [516.6, 67.9, 534.5, 95.8] | 17.9x27.9 | False | True | False | False | Dropped: conf 0.08 < thresh 0.35 |
| 47 | `transformer` | 0.078 | 0.50 | [464.0, 469.7, 478.0, 502.1] | 14.0x32.4 | False | True | False | True | Dropped: conf 0.08 < thresh 0.50 |
| 48 | `load` | 0.069 | 0.35 | [144.5, 444.0, 155.5, 470.4] | 11.1x26.4 | False | True | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 49 | `transformer` | 0.065 | 0.50 | [394.2, 469.5, 406.8, 501.4] | 12.6x31.9 | False | True | False | True | Dropped: conf 0.07 < thresh 0.50 |
| 50 | `load` | 0.063 | 0.35 | [459.6, 158.9, 470.4, 185.9] | 10.8x27.0 | False | False | False | False | Dropped: conf 0.06 < thresh 0.35 |
| 51 | `bus` | 0.062 | 0.30 | [1009.7, 349.2, 1033.4, 359.1] | 23.8x9.8 | True | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 52 | `bus` | 0.057 | 0.30 | [944.3, 122.0, 950.0, 248.0] | 5.8x126.0 | False | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 53 | `load` | 0.051 | 0.35 | [1001.9, 571.4, 1024.4, 603.4] | 22.5x32.0 | False | True | False | False | Dropped: conf 0.05 < thresh 0.35 |

## KakaoTalk_20260815_154947878_09.jpg (1050x1086)
**Issue Description**: Checklist #12/#13: Bus box span truncation

- **Final Pipeline Output**: Total 80 nodes, 79 lines
  - Counts: {'transformer': 12, 'generator': 10, 'load': 19, 'bus': 39}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 92 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `transformer` | 0.961 | 0.50 | [625.2, 790.4, 670.6, 855.0] | 45.3x64.6 | True | False | True | False | Kept |
| 1 | `transformer` | 0.959 | 0.50 | [383.9, 710.2, 428.6, 774.4] | 44.7x64.2 | True | False | True | True | Kept |
| 2 | `transformer` | 0.959 | 0.50 | [258.6, 871.1, 303.7, 935.7] | 45.1x64.5 | True | False | True | True | Kept |
| 3 | `transformer` | 0.948 | 0.50 | [624.3, 931.4, 670.7, 996.2] | 46.4x64.9 | True | False | True | False | Kept |
| 4 | `generator` | 0.941 | 0.52 | [724.3, 1031.1, 769.9, 1076.5] | 45.7x45.4 | True | True | False | True | Kept |
| 5 | `generator` | 0.925 | 0.52 | [625.1, 1031.4, 670.6, 1076.4] | 45.5x44.9 | True | True | False | True | Kept |
| 6 | `load` | 0.922 | 0.35 | [336.7, 977.3, 355.2, 993.7] | 18.5x16.4 | True | True | False | False | Kept |
| 7 | `generator` | 0.922 | 0.52 | [906.0, 328.3, 952.0, 371.8] | 46.0x43.6 | True | True | False | True | Kept |
| 8 | `generator` | 0.922 | 0.52 | [259.4, 973.5, 304.0, 1017.1] | 44.6x43.6 | True | True | False | True | Kept |
| 9 | `load` | 0.921 | 0.35 | [177.5, 839.6, 192.1, 854.6] | 14.7x14.9 | True | True | False | False | Kept |
| 10 | `generator` | 0.916 | 0.52 | [22.2, 468.9, 66.4, 513.2] | 44.1x44.3 | True | True | False | True | Kept |
| 11 | `transformer` | 0.912 | 0.50 | [866.1, 790.1, 911.4, 855.3] | 45.4x65.2 | True | False | True | True | Kept |
| 12 | `generator` | 0.908 | 0.52 | [866.5, 891.8, 911.4, 935.7] | 44.9x43.9 | True | True | False | True | Kept |
| 13 | `load` | 0.905 | 0.35 | [469.6, 147.9, 485.4, 162.9] | 15.8x15.0 | True | True | False | False | Kept |
| 14 | `generator` | 0.904 | 0.52 | [905.8, 408.2, 951.8, 452.2] | 45.9x43.9 | True | True | False | True | Kept |
| 15 | `load` | 0.897 | 0.35 | [698.6, 213.5, 717.0, 229.4] | 18.4x15.9 | True | True | False | False | Kept |
| 16 | `generator` | 0.896 | 0.52 | [443.8, 1032.6, 489.4, 1076.5] | 45.5x43.9 | True | True | False | True | Kept |
| 17 | `transformer` | 0.886 | 0.50 | [444.5, 931.5, 490.2, 995.9] | 45.7x64.4 | True | False | True | False | Kept |
| 18 | `load` | 0.884 | 0.35 | [196.4, 510.6, 213.7, 526.2] | 17.3x15.7 | True | True | False | False | Kept |
| 19 | `load` | 0.883 | 0.35 | [34.8, 575.5, 54.0, 592.7] | 19.2x17.2 | True | True | False | False | Kept |
| 20 | `transformer` | 0.883 | 0.50 | [444.6, 711.0, 489.1, 774.2] | 44.5x63.2 | True | False | True | False | Kept |
| 21 | `load` | 0.882 | 0.35 | [267.0, 214.2, 284.9, 229.8] | 17.9x15.6 | True | True | False | False | Kept |
| 22 | `generator` | 0.880 | 0.52 | [253.7, 5.8, 298.6, 49.4] | 44.8x43.7 | True | True | False | True | Kept |
| 23 | `load` | 0.876 | 0.35 | [227.7, 759.1, 243.9, 772.5] | 16.2x13.5 | True | True | False | False | Kept |
| 24 | `transformer` | 0.875 | 0.50 | [724.2, 831.2, 769.3, 896.2] | 45.1x65.0 | True | False | True | False | Kept |
| 25 | `load` | 0.874 | 0.35 | [549.6, 294.8, 566.1, 309.0] | 16.4x14.2 | True | True | False | False | Kept |
| 26 | `generator` | 0.871 | 0.52 | [133.0, 106.2, 177.7, 150.0] | 44.7x43.8 | True | True | False | True | Kept |
| 27 | `load` | 0.865 | 0.35 | [599.3, 852.9, 614.2, 867.6] | 14.8x14.7 | True | True | False | False | Kept |
| 28 | `transformer` | 0.852 | 0.50 | [132.7, 187.0, 177.2, 251.4] | 44.6x64.4 | True | False | True | False | Kept |
| 29 | `load` | 0.850 | 0.35 | [348.6, 355.5, 364.1, 370.2] | 15.5x14.7 | True | True | False | False | Kept |
| 30 | `load` | 0.841 | 0.35 | [307.5, 435.2, 324.4, 451.0] | 16.9x15.7 | True | True | False | False | Kept |
| 31 | `load` | 0.832 | 0.35 | [426.8, 631.0, 441.9, 646.5] | 15.1x15.5 | True | True | False | False | Kept |
| 32 | `bus` | 0.829 | 0.30 | [886.4, 589.9, 971.0, 596.4] | 84.6x6.5 | True | False | False | False | Kept |
| 33 | `bus` | 0.824 | 0.30 | [455.1, 186.3, 578.8, 191.0] | 123.7x4.8 | True | False | False | False | Kept |
| 34 | `load` | 0.805 | 0.35 | [880.8, 711.2, 896.5, 727.1] | 15.7x15.9 | True | True | False | False | Kept |
| 35 | `load` | 0.801 | 0.35 | [778.3, 314.7, 796.2, 330.2] | 17.9x15.5 | True | True | False | False | Kept |
| 36 | `load` | 0.801 | 0.35 | [718.5, 617.5, 737.3, 633.2] | 18.8x15.7 | True | True | False | False | Kept |
| 37 | `bus` | 0.799 | 0.30 | [444.3, 789.9, 546.1, 795.5] | 101.8x5.6 | False | False | False | False | Kept |
| 38 | `bus` | 0.796 | 0.30 | [82.2, 366.1, 146.6, 374.8] | 64.4x8.8 | False | False | False | False | Kept |
| 39 | `bus` | 0.783 | 0.30 | [497.7, 488.0, 581.3, 493.7] | 83.6x5.7 | False | False | False | False | Kept |
| 40 | `bus` | 0.781 | 0.30 | [496.8, 266.6, 578.7, 271.7] | 81.9x5.2 | False | False | False | False | Kept |
| 41 | `load` | 0.778 | 0.35 | [920.2, 146.9, 937.3, 163.6] | 17.0x16.8 | True | True | False | False | Kept |
| 42 | `bus` | 0.773 | 0.30 | [121.8, 809.9, 207.0, 816.4] | 85.2x6.5 | False | False | False | False | Kept |
| 43 | `load` | 0.769 | 0.35 | [550.3, 515.8, 567.3, 530.9] | 17.0x15.1 | True | True | False | False | Kept |
| 44 | `transformer` | 0.753 | 0.50 | [905.7, 227.1, 951.6, 291.2] | 45.9x64.2 | True | False | True | False | Kept |
| 45 | `bus` | 0.751 | 0.30 | [705.9, 589.4, 791.4, 596.5] | 85.5x7.1 | False | False | False | False | Kept |
| 46 | `load` | 0.747 | 0.35 | [596.9, 454.6, 615.3, 470.5] | 18.4x15.9 | True | True | False | False | Kept |
| 47 | `bus` | 0.746 | 0.30 | [113.7, 166.4, 198.7, 172.4] | 85.0x6.0 | True | False | False | False | Kept |
| 48 | `bus` | 0.733 | 0.30 | [583.6, 890.9, 668.8, 896.2] | 85.2x5.2 | False | False | False | False | Kept |
| 49 | `bus` | 0.726 | 0.30 | [456.4, 327.2, 541.9, 333.1] | 85.4x6.0 | False | False | False | False | Kept |
| 50 | `bus` | 0.724 | 0.30 | [162.6, 729.0, 248.5, 735.5] | 85.9x6.6 | False | False | False | False | Kept |
| 51 | `bus` | 0.720 | 0.30 | [243.6, 951.2, 363.5, 956.9] | 120.0x5.7 | False | False | False | False | Kept |
| 52 | `bus` | 0.720 | 0.30 | [656.9, 186.3, 761.2, 191.7] | 104.3x5.4 | True | False | False | False | Kept |
| 53 | `bus` | 0.716 | 0.30 | [384.1, 669.7, 485.9, 675.1] | 101.8x5.4 | True | False | False | False | Kept |
| 54 | `bus` | 0.711 | 0.30 | [213.8, 186.8, 386.8, 191.4] | 173.0x4.6 | True | False | False | False | Kept |
| 55 | `bus` | 0.706 | 0.30 | [22.6, 548.2, 127.5, 556.0] | 104.8x7.8 | False | False | False | False | Kept |
| 56 | `bus` | 0.696 | 0.30 | [824.6, 186.5, 978.3, 191.3] | 153.7x4.9 | False | False | False | False | Kept |
| 57 | `bus` | 0.680 | 0.30 | [293.8, 327.2, 378.9, 333.1] | 85.0x5.9 | False | False | False | False | Kept |
| 58 | `bus` | 0.676 | 0.30 | [184.0, 549.4, 288.5, 555.0] | 104.5x5.7 | True | False | False | False | Kept |
| 59 | `bus` | 0.672 | 0.30 | [444.7, 549.3, 548.0, 555.1] | 103.4x5.9 | False | False | False | False | Kept |
| 60 | `bus` | 0.668 | 0.30 | [80.6, 870.7, 165.3, 875.8] | 84.7x5.2 | False | False | False | False | Kept |
| 61 | `bus` | 0.665 | 0.30 | [845.8, 870.6, 930.1, 875.5] | 84.2x4.9 | True | False | False | False | Kept |
| 62 | `bus` | 0.664 | 0.30 | [464.7, 426.9, 632.4, 432.9] | 167.7x6.0 | True | False | False | False | Kept |
| 63 | `bus` | 0.659 | 0.30 | [424.6, 1011.7, 504.8, 1016.8] | 80.2x5.0 | True | False | False | False | Kept |
| 64 | `bus` | 0.653 | 0.30 | [624.5, 750.2, 767.4, 755.7] | 142.9x5.4 | False | False | False | False | Kept |
| 65 | `bus` | 0.651 | 0.30 | [234.1, 66.0, 317.8, 70.6] | 83.7x4.6 | True | False | False | False | Kept |
| 66 | `bus` | 0.641 | 0.30 | [303.5, 830.4, 426.7, 836.0] | 123.2x5.6 | False | False | False | False | Kept |
| 67 | `bus` | 0.635 | 0.30 | [887.1, 468.0, 971.2, 473.1] | 84.1x5.1 | True | False | False | False | Kept |
| 68 | `transformer` | 0.634 | 0.50 | [904.6, 488.5, 952.9, 554.7] | 48.3x66.2 | True | False | True | False | Kept |
| 69 | `bus` | 0.623 | 0.30 | [603.9, 1010.8, 690.2, 1016.8] | 86.3x6.0 | True | False | False | False | Kept |
| 70 | `transformer` | 0.609 | 0.50 | [254.1, 85.4, 299.8, 150.3] | 45.7x64.9 | True | False | True | False | Kept |
| 71 | `bus` | 0.604 | 0.30 | [724.5, 287.3, 849.7, 292.8] | 125.2x5.5 | True | False | False | False | Kept |
| 72 | `bus` | 0.602 | 0.30 | [885.8, 306.9, 972.3, 311.9] | 86.5x5.0 | True | False | False | False | Kept |
| 73 | `bus` | 0.602 | 0.30 | [705.0, 1009.3, 791.8, 1018.7] | 86.8x9.5 | True | False | False | False | Kept |
| 74 | `bus` | 0.547 | 0.30 | [172.9, 408.4, 341.2, 413.5] | 168.2x5.1 | True | False | False | False | Kept |
| 75 | `bus` | 0.470 | 0.30 | [867.5, 750.9, 1032.6, 755.6] | 165.1x4.6 | False | False | False | False | Kept |
| 76 | `bus` | 0.447 | 0.30 | [202.2, 669.8, 350.9, 675.3] | 148.7x5.6 | True | False | False | False | Kept |
| 77 | `bus` | 0.439 | 0.30 | [94.7, 288.1, 264.8, 292.9] | 170.1x4.8 | True | False | False | False | Kept |
| 78 | `bus` | 0.317 | 0.30 | [366.3, 890.9, 516.7, 896.0] | 150.4x5.1 | True | False | False | False | Kept |
| 79 | `generator` | 0.272 | 0.52 | [253.4, 86.7, 299.1, 150.2] | 45.7x63.5 | True | False | True | False | Dropped: conf 0.27 < thresh 0.52 |
| 80 | `bus` | 0.253 | 0.30 | [122.2, 608.2, 249.3, 613.7] | 127.0x5.5 | True | False | False | False | Dropped: conf 0.25 < thresh 0.30 |
| 81 | `bus` | 0.178 | 0.30 | [637.6, 425.4, 769.9, 433.9] | 132.3x8.5 | True | False | False | False | Dropped: conf 0.18 < thresh 0.30 |
| 82 | `generator` | 0.174 | 0.52 | [905.7, 488.7, 952.8, 555.1] | 47.1x66.3 | True | False | True | False | Dropped: conf 0.17 < thresh 0.52 |
| 83 | `generator` | 0.153 | 0.52 | [444.0, 932.5, 490.4, 995.0] | 46.4x62.5 | True | False | True | True | Dropped: conf 0.15 < thresh 0.52 |
| 84 | `bus` | 0.133 | 0.30 | [1040.2, -1.6, 1051.4, 140.1] | 11.2x141.7 | True | False | False | False | Dropped: conf 0.13 < thresh 0.30 |
| 85 | `transformer` | 0.116 | 0.50 | [970.7, 177.2, 994.6, 197.1] | 23.9x19.9 | True | True | False | False | Dropped: conf 0.12 < thresh 0.50 |
| 86 | `generator` | 0.095 | 0.52 | [905.9, 227.8, 951.0, 291.2] | 45.1x63.4 | True | False | True | False | Dropped: conf 0.10 < thresh 0.52 |
| 87 | `bus` | 0.083 | 0.30 | [311.9, 950.7, 367.4, 957.2] | 55.5x6.5 | True | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 88 | `bus` | 0.066 | 0.30 | [282.3, 408.4, 358.2, 413.1] | 75.8x4.7 | True | False | False | False | Dropped: conf 0.07 < thresh 0.30 |
| 89 | `bus` | 0.063 | 0.30 | [198.1, 608.8, 266.5, 613.6] | 68.4x4.8 | True | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 90 | `load` | 0.062 | 0.35 | [400.6, 177.8, 422.1, 197.0] | 21.5x19.3 | False | True | False | False | Dropped: conf 0.06 < thresh 0.35 |
| 91 | `load` | 0.054 | 0.35 | [973.8, 299.4, 988.1, 317.8] | 14.3x18.4 | False | True | False | False | Dropped: conf 0.05 < thresh 0.35 |

## KakaoTalk_20260815_154947878_13.jpg (574x597)
**Issue Description**: Checklist #14-#16: Missing generator & load

- **Final Pipeline Output**: Total 56 nodes, 89 lines
  - Counts: {'transformer': 5, 'generator': 10, 'bus': 24, 'load': 17}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 84 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `transformer` | 0.966 | 0.50 | [189.9, 305.8, 219.3, 323.0] | 29.4x17.2 | True | True | False | False | Kept |
| 1 | `generator` | 0.948 | 0.52 | [329.7, 6.1, 353.4, 26.4] | 23.7x20.4 | True | True | False | True | Kept |
| 2 | `generator` | 0.935 | 0.52 | [176.3, 193.2, 198.6, 213.5] | 22.3x20.3 | True | True | False | True | Kept |
| 3 | `bus` | 0.933 | 0.30 | [181.6, 368.7, 257.3, 375.3] | 75.7x6.6 | False | False | False | False | Kept |
| 4 | `load` | 0.931 | 0.35 | [513.5, 472.1, 527.1, 484.3] | 13.5x12.1 | True | True | False | False | Kept |
| 5 | `transformer` | 0.928 | 0.50 | [321.5, 302.4, 350.0, 321.0] | 28.5x18.7 | True | True | False | False | Kept |
| 6 | `transformer` | 0.916 | 0.50 | [354.7, 318.0, 382.4, 336.9] | 27.8x18.9 | True | True | False | False | Kept |
| 7 | `transformer` | 0.912 | 0.50 | [29.5, 308.6, 59.7, 328.6] | 30.2x20.0 | True | True | False | False | Kept |
| 8 | `load` | 0.909 | 0.35 | [131.6, 200.9, 146.1, 210.8] | 14.4x9.9 | True | True | False | False | Kept |
| 9 | `load` | 0.906 | 0.35 | [210.8, 464.6, 223.8, 476.5] | 13.1x11.9 | True | True | False | False | Kept |
| 10 | `generator` | 0.903 | 0.52 | [469.2, 110.8, 492.3, 131.7] | 23.1x20.9 | False | False | False | True | Kept |
| 11 | `load` | 0.896 | 0.35 | [513.7, 393.7, 526.8, 405.5] | 13.0x11.9 | True | True | False | False | Kept |
| 12 | `bus` | 0.887 | 0.30 | [317.5, 38.2, 359.9, 44.8] | 42.3x6.7 | False | False | False | False | Kept |
| 13 | `load` | 0.880 | 0.35 | [343.9, 345.5, 358.8, 357.6] | 15.0x12.1 | True | True | False | False | Kept |
| 14 | `load` | 0.875 | 0.35 | [248.2, 163.1, 261.8, 175.3] | 13.6x12.1 | True | True | False | False | Kept |
| 15 | `generator` | 0.867 | 0.52 | [542.2, 193.1, 566.2, 213.5] | 24.0x20.4 | True | True | False | True | Kept |
| 16 | `generator` | 0.858 | 0.52 | [216.0, 14.9, 239.1, 35.0] | 23.2x20.1 | True | False | False | True | Kept |
| 17 | `load` | 0.854 | 0.35 | [63.6, 127.2, 78.1, 139.0] | 14.5x11.7 | True | False | False | False | Kept |
| 18 | `bus` | 0.854 | 0.30 | [234.6, 550.4, 310.8, 558.0] | 76.1x7.6 | True | False | False | False | Kept |
| 19 | `bus` | 0.854 | 0.30 | [128.4, 443.6, 134.6, 479.4] | 6.3x35.8 | False | False | False | False | Kept |
| 20 | `load` | 0.852 | 0.35 | [106.1, 449.0, 119.3, 460.6] | 13.2x11.5 | True | True | False | False | Kept |
| 21 | `bus` | 0.845 | 0.30 | [30.8, 202.2, 90.1, 209.2] | 59.3x7.0 | False | False | False | False | Kept |
| 22 | `generator` | 0.841 | 0.52 | [260.1, 570.6, 284.9, 590.0] | 24.9x19.5 | True | True | False | True | Kept |
| 23 | `bus` | 0.840 | 0.30 | [58.9, 30.9, 119.2, 37.0] | 60.3x6.1 | False | False | False | False | Kept |
| 24 | `load` | 0.836 | 0.35 | [533.8, 216.0, 547.6, 227.5] | 13.8x11.4 | False | True | False | False | Vetoed: numeric text & no wire contact |
| 25 | `generator` | 0.835 | 0.52 | [451.0, 570.1, 474.9, 590.0] | 23.9x19.9 | False | True | False | True | Vetoed: numeric text & no wire contact |
| 26 | `bus` | 0.835 | 0.30 | [497.0, 387.9, 503.3, 426.5] | 6.3x38.6 | False | False | False | False | Kept |
| 27 | `bus` | 0.832 | 0.30 | [58.5, 549.1, 135.2, 556.9] | 76.7x7.7 | True | False | False | False | Kept |
| 28 | `load` | 0.828 | 0.35 | [72.4, 218.3, 87.1, 228.3] | 14.7x10.0 | True | True | False | False | Kept |
| 29 | `bus` | 0.824 | 0.30 | [179.9, 272.8, 257.6, 279.2] | 77.7x6.4 | True | False | False | False | Kept |
| 30 | `bus` | 0.823 | 0.30 | [233.4, 459.1, 240.8, 496.2] | 7.4x37.0 | False | False | False | False | Kept |
| 31 | `bus` | 0.821 | 0.30 | [42.1, 148.0, 101.7, 154.3] | 59.6x6.3 | True | False | False | False | Kept |
| 32 | `bus` | 0.818 | 0.30 | [23.8, 276.6, 64.6, 281.7] | 40.8x5.0 | True | False | False | False | Kept |
| 33 | `generator` | 0.817 | 0.52 | [66.9, 576.7, 90.0, 597.1] | 23.1x20.5 | False | True | False | True | Vetoed: numeric text & no wire contact |
| 34 | `load` | 0.803 | 0.35 | [288.6, 565.9, 302.9, 578.7] | 14.3x12.8 | True | True | False | False | Kept |
| 35 | `load` | 0.793 | 0.35 | [344.4, 163.1, 357.9, 175.4] | 13.5x12.3 | True | True | False | False | Kept |
| 36 | `bus` | 0.790 | 0.30 | [322.7, 147.4, 381.3, 154.0] | 58.6x6.5 | True | False | False | False | Kept |
| 37 | `bus` | 0.776 | 0.30 | [320.6, 365.3, 381.1, 372.6] | 60.5x7.4 | True | False | False | False | Kept |
| 38 | `bus` | 0.775 | 0.30 | [495.1, 458.1, 501.9, 494.5] | 6.7x36.3 | True | False | False | False | Kept |
| 39 | `generator` | 0.774 | 0.52 | [68.3, -1.0, 91.0, 20.2] | 22.7x21.2 | True | False | False | True | Kept |
| 40 | `bus` | 0.773 | 0.30 | [320.2, 272.6, 379.5, 279.2] | 59.3x6.6 | True | False | False | False | Kept |
| 41 | `bus` | 0.770 | 0.30 | [7.0, 61.8, 12.7, 108.2] | 5.7x46.4 | True | False | False | False | Kept |
| 42 | `load` | 0.765 | 0.35 | [47.5, 352.8, 62.9, 364.1] | 15.4x11.3 | True | True | False | False | Kept |
| 43 | `bus` | 0.758 | 0.30 | [16.0, 368.3, 65.6, 375.1] | 49.6x6.8 | False | False | False | False | Kept |
| 44 | `bus` | 0.757 | 0.30 | [185.8, 46.9, 263.5, 52.3] | 77.7x5.4 | False | False | False | False | Kept |
| 45 | `bus` | 0.746 | 0.30 | [426.3, 551.0, 487.1, 559.2] | 60.8x8.2 | False | False | False | False | Kept |
| 46 | `load` | 0.732 | 0.35 | [441.5, 533.3, 453.6, 543.3] | 12.1x10.0 | False | True | False | False | Vetoed: numeric text & no wire contact |
| 47 | `bus` | 0.724 | 0.30 | [215.6, 147.8, 275.9, 153.7] | 60.3x5.9 | False | False | False | False | Kept |
| 48 | `bus` | 0.707 | 0.30 | [516.2, 181.6, 523.5, 234.1] | 7.3x52.5 | False | False | False | False | Kept |
| 49 | `bus` | 0.704 | 0.30 | [154.9, 192.1, 161.9, 230.1] | 7.0x38.0 | False | False | False | False | Kept |
| 50 | `bus` | 0.691 | 0.30 | [444.1, 109.4, 451.1, 154.7] | 7.0x45.3 | True | False | False | False | Kept |
| 51 | `load` | 0.680 | 0.35 | [93.1, 9.1, 104.1, 21.7] | 11.1x12.6 | True | True | False | False | Kept |
| 52 | `generator` | 0.653 | 0.52 | [53.5, 220.9, 75.1, 240.3] | 21.5x19.4 | True | True | False | True | Kept |
| 53 | `load` | 0.629 | 0.35 | [107.2, 566.0, 122.7, 580.4] | 15.5x14.4 | True | True | False | False | Kept |
| 54 | `transformer` | 0.619 | 0.50 | [225.0, 321.7, 251.0, 340.3] | 26.0x18.7 | True | True | False | False | Kept |
| 55 | `load` | 0.592 | 0.35 | [510.6, 448.0, 525.1, 455.8] | 14.5x7.8 | True | True | False | False | Kept |
| 56 | `load` | 0.539 | 0.35 | [222.4, 353.6, 233.3, 365.0] | 10.9x11.3 | True | True | False | False | Kept |
| 57 | `generator` | 0.434 | 0.52 | [23.1, 117.1, 44.8, 136.8] | 21.7x19.6 | True | True | False | True | Dropped: conf 0.43 < thresh 0.52 |
| 58 | `bus` | 0.375 | 0.30 | [194.0, -106.5, 927.0, 69.6] | 733.0x176.1 | False | False | True | False | Kept |
| 59 | `bus` | 0.255 | 0.30 | [162.3, -170.7, 927.0, -26.4] | 764.7x144.3 | False | False | False | False | Dropped: conf 0.26 < thresh 0.30 |
| 60 | `bus` | 0.194 | 0.30 | [260.6, -10.5, 927.0, 158.0] | 666.4x168.5 | True | False | True | False | Dropped: conf 0.19 < thresh 0.30 |
| 61 | `bus` | 0.177 | 0.30 | [-353.0, -170.5, 391.5, -29.7] | 744.5x140.9 | False | False | False | False | Dropped: conf 0.18 < thresh 0.30 |
| 62 | `load` | 0.166 | 0.35 | [29.2, 307.2, 58.7, 327.3] | 29.5x20.1 | True | True | False | False | Dropped: conf 0.17 < thresh 0.35 |
| 63 | `load` | 0.155 | 0.35 | [355.7, 315.9, 383.2, 339.3] | 27.5x23.4 | True | True | False | True | Dropped: conf 0.15 < thresh 0.35 |
| 64 | `bus` | 0.126 | 0.30 | [-353.0, -107.1, 357.7, 41.1] | 710.7x148.1 | True | False | True | False | Dropped: conf 0.13 < thresh 0.30 |
| 65 | `bus` | 0.110 | 0.30 | [299.0, 85.2, 927.0, 228.3] | 628.0x143.1 | False | False | True | False | Dropped: conf 0.11 < thresh 0.30 |
| 66 | `bus` | 0.101 | 0.30 | [329.3, 149.4, 927.0, 285.6] | 597.7x136.2 | False | False | True | False | Dropped: conf 0.10 < thresh 0.30 |
| 67 | `bus` | 0.101 | 0.30 | [355.6, 533.8, 927.0, 666.9] | 571.4x133.1 | False | False | False | False | Dropped: conf 0.10 < thresh 0.30 |
| 68 | `bus` | 0.096 | 0.30 | [355.8, 597.8, 927.0, 733.6] | 571.2x135.8 | False | False | False | False | Dropped: conf 0.10 < thresh 0.30 |
| 69 | `bus` | 0.095 | 0.30 | [355.9, 469.9, 927.0, 597.8] | 571.1x127.9 | False | False | True | False | Dropped: conf 0.10 < thresh 0.30 |
| 70 | `bus` | 0.092 | 0.30 | [358.3, 213.9, 927.0, 346.7] | 568.7x132.8 | True | False | True | False | Dropped: conf 0.09 < thresh 0.30 |
| 71 | `bus` | 0.090 | 0.30 | [-121.8, -202.6, 805.4, -47.8] | 927.2x154.8 | False | False | False | False | Dropped: conf 0.09 < thresh 0.30 |
| 72 | `bus` | 0.086 | 0.30 | [357.5, 405.8, 927.0, 528.8] | 569.5x123.0 | False | False | True | False | Dropped: conf 0.09 < thresh 0.30 |
| 73 | `bus` | 0.085 | 0.30 | [360.1, 277.8, 927.0, 404.4] | 566.9x126.6 | False | False | True | False | Dropped: conf 0.08 < thresh 0.30 |
| 74 | `bus` | 0.083 | 0.30 | [68.2, -234.3, 927.0, -126.6] | 858.8x107.7 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 75 | `bus` | 0.082 | 0.30 | [359.3, 341.8, 927.0, 466.0] | 567.7x124.2 | False | False | True | False | Dropped: conf 0.08 < thresh 0.30 |
| 76 | `bus` | 0.081 | 0.30 | [357.3, 661.8, 927.0, 801.3] | 569.7x139.5 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 77 | `bus` | 0.080 | 0.30 | [-353.0, -234.3, 390.6, -128.8] | 743.6x105.5 | False | False | False | False | Dropped: conf 0.08 < thresh 0.30 |
| 78 | `bus` | 0.072 | 0.30 | [-353.0, -9.7, 324.4, 118.6] | 677.4x128.3 | True | False | True | False | Dropped: conf 0.07 < thresh 0.30 |
| 79 | `load` | 0.070 | 0.35 | [510.5, 390.5, 542.9, 414.3] | 32.5x23.8 | True | False | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 80 | `load` | 0.067 | 0.35 | [143.6, 429.8, 155.5, 446.0] | 11.9x16.2 | True | True | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 81 | `load` | 0.061 | 0.35 | [127.9, 207.9, 136.4, 216.9] | 8.5x9.1 | True | True | False | False | Dropped: conf 0.06 < thresh 0.35 |
| 82 | `bus` | 0.060 | 0.30 | [-353.0, 54.8, 324.2, 189.7] | 677.2x135.0 | False | False | True | False | Dropped: conf 0.06 < thresh 0.30 |
| 83 | `bus` | 0.055 | 0.30 | [364.5, 725.8, 927.0, 870.9] | 562.5x145.0 | False | False | False | False | Dropped: conf 0.05 < thresh 0.30 |

## KakaoTalk_20260815_154956634_04.jpg (958x835)
**Issue Description**: Checklist #17-#20: Missing 4 transformers

- **Final Pipeline Output**: Total 59 nodes, 90 lines
  - Counts: {'generator': 6, 'load': 22, 'bus': 31}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 67 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `generator` | 0.964 | 0.52 | [571.6, 762.5, 632.8, 812.7] | 61.2x50.3 | True | False | False | True | Kept |
| 1 | `generator` | 0.961 | 0.52 | [284.8, 762.8, 345.6, 812.6] | 60.8x49.8 | True | False | False | True | Kept |
| 2 | `generator` | 0.955 | 0.52 | [51.4, 690.8, 113.4, 740.4] | 62.0x49.6 | True | False | False | True | Kept |
| 3 | `generator` | 0.955 | 0.52 | [773.6, 660.1, 835.9, 713.7] | 62.3x53.7 | True | False | False | True | Kept |
| 4 | `load` | 0.946 | 0.35 | [468.7, 531.0, 486.4, 548.6] | 17.7x17.6 | True | True | False | False | Kept |
| 5 | `generator` | 0.938 | 0.52 | [345.5, 515.4, 404.1, 567.8] | 58.6x52.4 | True | False | False | True | Kept |
| 6 | `load` | 0.918 | 0.35 | [401.9, 139.7, 420.7, 158.1] | 18.8x18.4 | True | True | False | False | Kept |
| 7 | `load` | 0.916 | 0.35 | [157.8, 436.9, 177.4, 454.8] | 19.5x18.0 | True | True | False | False | Kept |
| 8 | `load` | 0.913 | 0.35 | [136.4, 70.2, 155.1, 87.8] | 18.7x17.6 | True | True | False | False | Kept |
| 9 | `generator` | 0.912 | 0.52 | [109.0, 542.2, 170.3, 592.8] | 61.3x50.7 | True | False | False | True | Kept |
| 10 | `load` | 0.912 | 0.35 | [468.7, 289.1, 488.1, 306.6] | 19.4x17.5 | True | True | False | False | Kept |
| 11 | `load` | 0.910 | 0.35 | [706.5, 692.1, 727.9, 712.6] | 21.4x20.5 | True | True | False | False | Kept |
| 12 | `load` | 0.902 | 0.35 | [294.2, 655.2, 313.9, 671.6] | 19.7x16.4 | True | True | False | False | Kept |
| 13 | `bus` | 0.901 | 0.30 | [552.0, 727.4, 613.9, 737.5] | 61.9x10.1 | False | False | False | False | Kept |
| 14 | `load` | 0.901 | 0.35 | [137.6, 139.8, 156.5, 158.9] | 18.8x19.1 | True | True | False | False | Kept |
| 15 | `load` | 0.895 | 0.35 | [463.1, 671.4, 484.2, 689.3] | 21.1x17.9 | True | True | False | False | Kept |
| 16 | `load` | 0.894 | 0.35 | [680.4, 348.8, 699.0, 367.1] | 18.6x18.3 | True | True | False | False | Kept |
| 17 | `bus` | 0.884 | 0.30 | [66.5, 641.9, 127.6, 651.7] | 61.1x9.8 | False | False | False | False | Kept |
| 18 | `bus` | 0.882 | 0.30 | [444.4, 273.8, 505.9, 281.1] | 61.5x7.4 | False | False | False | False | Kept |
| 19 | `bus` | 0.882 | 0.30 | [755.1, 615.9, 817.9, 625.8] | 62.7x9.9 | True | False | False | False | Kept |
| 20 | `load` | 0.881 | 0.35 | [663.3, 192.0, 681.7, 208.0] | 18.4x16.1 | True | True | False | False | Kept |
| 21 | `load` | 0.877 | 0.35 | [493.8, 225.9, 513.8, 243.5] | 19.9x17.5 | True | True | False | False | Kept |
| 22 | `load` | 0.876 | 0.35 | [249.3, 288.4, 268.7, 306.7] | 19.4x18.3 | True | True | False | False | Kept |
| 23 | `bus` | 0.873 | 0.30 | [273.5, 726.1, 334.6, 735.1] | 61.1x9.0 | True | False | False | False | Kept |
| 24 | `bus` | 0.873 | 0.30 | [273.4, 633.7, 336.3, 641.6] | 62.9x8.0 | True | False | False | False | Kept |
| 25 | `bus` | 0.868 | 0.30 | [124.2, 512.3, 183.8, 520.0] | 59.6x7.7 | False | False | False | False | Kept |
| 26 | `bus` | 0.866 | 0.30 | [504.4, 545.5, 565.4, 553.0] | 61.0x7.6 | False | False | False | False | Kept |
| 27 | `bus` | 0.864 | 0.30 | [643.8, 171.7, 705.6, 178.5] | 61.8x6.8 | True | False | False | False | Kept |
| 28 | `load` | 0.862 | 0.35 | [276.2, 745.6, 297.1, 764.2] | 20.9x18.6 | True | True | False | False | Kept |
| 29 | `bus` | 0.859 | 0.30 | [399.0, 67.3, 459.0, 74.8] | 59.9x7.5 | False | False | False | False | Kept |
| 30 | `load` | 0.859 | 0.35 | [553.0, 745.9, 575.9, 766.9] | 23.0x21.0 | True | True | False | False | Kept |
| 31 | `bus` | 0.855 | 0.30 | [750.9, 47.2, 811.8, 55.7] | 60.9x8.6 | False | False | False | False | Kept |
| 32 | `bus` | 0.853 | 0.30 | [609.1, 112.5, 670.5, 119.9] | 61.3x7.4 | False | False | False | False | Kept |
| 33 | `bus` | 0.849 | 0.30 | [227.7, 273.0, 289.6, 281.7] | 61.8x8.7 | True | False | False | False | Kept |
| 34 | `bus` | 0.844 | 0.30 | [434.7, 646.8, 497.9, 654.8] | 63.3x7.9 | False | False | False | False | Kept |
| 35 | `load` | 0.839 | 0.35 | [447.2, 438.0, 466.6, 455.3] | 19.4x17.2 | True | True | False | False | Kept |
| 36 | `bus` | 0.838 | 0.30 | [676.8, 675.6, 741.0, 684.5] | 64.1x9.0 | True | False | False | False | Kept |
| 37 | `bus` | 0.837 | 0.30 | [244.2, 512.7, 305.6, 519.9] | 61.4x7.2 | True | False | False | False | Kept |
| 38 | `bus` | 0.817 | 0.30 | [462.1, 211.2, 522.8, 218.9] | 60.6x7.7 | False | False | False | False | Kept |
| 39 | `bus` | 0.816 | 0.30 | [116.0, 125.6, 177.2, 132.6] | 61.2x7.0 | True | False | False | False | Kept |
| 40 | `load` | 0.814 | 0.35 | [685.8, 409.9, 704.0, 426.6] | 18.2x16.7 | True | True | False | False | Kept |
| 41 | `load` | 0.813 | 0.35 | [680.7, 288.2, 700.5, 306.6] | 19.8x18.4 | True | True | False | False | Kept |
| 42 | `bus` | 0.809 | 0.30 | [694.0, 434.7, 755.8, 442.3] | 61.9x7.5 | False | False | False | False | Kept |
| 43 | `load` | 0.809 | 0.35 | [487.6, 343.3, 506.2, 360.1] | 18.6x16.8 | True | True | False | False | Kept |
| 44 | `bus` | 0.797 | 0.30 | [115.7, 40.2, 178.3, 47.9] | 62.5x7.8 | True | False | False | False | Kept |
| 45 | `bus` | 0.793 | 0.30 | [616.0, 619.1, 679.4, 626.9] | 63.4x7.8 | True | False | False | False | Kept |
| 46 | `bus` | 0.767 | 0.30 | [645.0, 274.2, 706.6, 282.1] | 61.5x7.9 | True | False | False | False | Kept |
| 47 | `bus` | 0.764 | 0.30 | [151.6, 410.5, 213.5, 418.3] | 61.9x7.8 | True | False | False | False | Kept |
| 48 | `load` | 0.760 | 0.35 | [759.1, 632.4, 779.5, 650.7] | 20.4x18.4 | True | True | False | False | Kept |
| 49 | `bus` | 0.755 | 0.30 | [467.7, 513.5, 530.3, 520.6] | 62.6x7.1 | True | False | False | False | Kept |
| 50 | `load` | 0.749 | 0.35 | [265.3, 530.5, 282.0, 549.2] | 16.7x18.6 | True | True | False | False | Kept |
| 51 | `bus` | 0.742 | 0.30 | [668.7, 390.5, 729.9, 397.3] | 61.3x6.9 | False | False | False | False | Kept |
| 52 | `bus` | 0.741 | 0.30 | [645.0, 335.5, 705.2, 343.1] | 60.3x7.6 | True | False | False | False | Kept |
| 53 | `bus` | 0.730 | 0.30 | [451.0, 327.5, 513.6, 335.0] | 62.6x7.6 | False | False | False | False | Kept |
| 54 | `bus` | 0.718 | 0.30 | [410.8, 422.4, 471.3, 429.8] | 60.5x7.4 | True | False | False | False | Kept |
| 55 | `load` | 0.710 | 0.35 | [646.3, 236.7, 667.5, 247.2] | 21.2x10.4 | True | True | False | False | Kept |
| 56 | `bus` | 0.690 | 0.30 | [365.2, 486.3, 425.8, 494.1] | 60.7x7.8 | False | False | False | False | Kept |
| 57 | `bus` | 0.614 | 0.30 | [398.1, 111.6, 458.3, 118.4] | 60.2x6.7 | False | False | False | False | Kept |
| 58 | `bus` | 0.248 | 0.30 | [644.6, 490.0, 649.3, 614.7] | 4.6x124.7 | True | False | False | False | Dropped: conf 0.25 < thresh 0.30 |
| 59 | `bus` | 0.200 | 0.30 | [481.0, 556.0, 504.5, 562.4] | 23.5x6.4 | True | True | False | False | Dropped: conf 0.20 < thresh 0.30 |
| 60 | `transformer` | 0.182 | 0.50 | [570.7, 478.3, 609.7, 502.2] | 39.0x23.9 | True | False | True | False | Dropped: conf 0.18 < thresh 0.50 |
| 61 | `transformer` | 0.095 | 0.50 | [569.8, 0.8, 611.4, 25.3] | 41.7x24.5 | True | False | True | False | Dropped: conf 0.10 < thresh 0.50 |
| 62 | `transformer` | 0.084 | 0.50 | [570.6, 562.2, 611.6, 585.9] | 41.0x23.7 | True | False | True | False | Dropped: conf 0.08 < thresh 0.50 |
| 63 | `load` | 0.069 | 0.35 | [483.1, 575.7, 503.3, 584.8] | 20.2x9.1 | True | True | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 64 | `bus` | 0.068 | 0.30 | [645.6, 218.6, 669.6, 224.6] | 24.0x5.9 | True | False | False | False | Dropped: conf 0.07 < thresh 0.30 |
| 65 | `generator` | 0.064 | 0.52 | [322.7, 591.6, 358.8, 614.2] | 36.1x22.6 | True | False | True | False | Dropped: conf 0.06 < thresh 0.52 |
| 66 | `transformer` | 0.057 | 0.50 | [319.9, 591.4, 359.0, 614.7] | 39.1x23.3 | True | False | True | False | Dropped: conf 0.06 < thresh 0.50 |

## KakaoTalk_20260815_154956634_05.jpg (930x748)
**Issue Description**: Checklist #21-#24: Missing load candidates

- **Final Pipeline Output**: Total 53 nodes, 83 lines
  - Counts: {'bus': 30, 'generator': 6, 'load': 17}
- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: 77 boxes

| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `bus` | 0.948 | 0.30 | [130.0, 563.8, 231.9, 576.3] | 101.8x12.5 | False | False | False | False | Kept |
| 1 | `bus` | 0.943 | 0.30 | [454.1, 356.0, 556.4, 367.6] | 102.4x11.6 | False | False | False | False | Kept |
| 2 | `bus` | 0.940 | 0.30 | [668.5, 156.5, 774.0, 167.5] | 105.4x11.0 | True | False | False | False | Kept |
| 3 | `bus` | 0.936 | 0.30 | [561.0, 356.1, 664.8, 367.3] | 103.9x11.2 | True | False | False | False | Kept |
| 4 | `bus` | 0.936 | 0.30 | [451.6, 564.1, 556.6, 575.5] | 105.0x11.5 | True | False | False | False | Kept |
| 5 | `bus` | 0.931 | 0.30 | [454.1, 617.6, 557.9, 629.9] | 103.8x12.2 | True | False | False | False | Kept |
| 6 | `bus` | 0.929 | 0.30 | [238.3, 563.7, 343.4, 575.9] | 105.0x12.2 | False | False | False | False | Kept |
| 7 | `generator` | 0.927 | 0.52 | [121.3, 702.3, 171.8, 749.0] | 50.5x46.8 | True | True | False | True | Kept |
| 8 | `bus` | 0.927 | 0.30 | [21.5, 356.0, 126.9, 367.4] | 105.3x11.4 | False | False | False | False | Kept |
| 9 | `bus` | 0.926 | 0.30 | [344.4, 355.9, 450.7, 367.6] | 106.3x11.6 | True | False | False | False | Kept |
| 10 | `bus` | 0.925 | 0.30 | [346.8, 247.9, 452.2, 259.8] | 105.3x11.8 | False | False | False | False | Kept |
| 11 | `generator` | 0.920 | 0.52 | [29.1, 478.9, 80.5, 528.2] | 51.3x49.3 | True | False | False | True | Kept |
| 12 | `bus` | 0.919 | 0.30 | [21.5, 564.3, 126.0, 575.2] | 104.5x10.9 | True | False | False | False | Kept |
| 13 | `bus` | 0.913 | 0.30 | [236.9, 156.1, 341.1, 167.3] | 104.2x11.2 | False | False | False | False | Kept |
| 14 | `bus` | 0.912 | 0.30 | [670.0, 355.7, 773.5, 367.9] | 103.5x12.2 | True | False | False | False | Kept |
| 15 | `bus` | 0.911 | 0.30 | [669.6, 71.0, 772.0, 82.2] | 102.5x11.3 | True | False | False | False | Kept |
| 16 | `bus` | 0.908 | 0.30 | [113.8, 671.3, 219.6, 683.0] | 105.8x11.7 | False | False | False | False | Kept |
| 17 | `bus` | 0.900 | 0.30 | [236.1, 71.3, 341.9, 81.5] | 105.8x10.3 | True | False | False | False | Kept |
| 18 | `bus` | 0.897 | 0.30 | [670.1, 247.9, 773.1, 259.2] | 103.0x11.2 | True | False | False | False | Kept |
| 19 | `bus` | 0.890 | 0.30 | [344.3, 670.6, 449.7, 684.3] | 105.4x13.7 | False | False | False | False | Kept |
| 20 | `bus` | 0.886 | 0.30 | [237.3, 355.8, 342.0, 367.7] | 104.7x11.9 | True | False | False | False | Kept |
| 21 | `generator` | 0.882 | 0.52 | [606.4, 386.1, 656.4, 437.0] | 50.0x50.8 | True | True | False | True | Kept |
| 22 | `bus` | 0.872 | 0.30 | [820.8, 563.1, 929.3, 576.5] | 108.5x13.4 | True | False | False | False | Kept |
| 23 | `bus` | 0.855 | 0.30 | [21.2, 456.0, 126.6, 467.9] | 105.4x11.8 | True | False | False | False | Kept |
| 24 | `bus` | 0.855 | 0.30 | [821.5, 355.9, 930.7, 367.2] | 109.2x11.3 | True | False | False | False | Kept |
| 25 | `generator` | 0.855 | 0.52 | [263.2, 1.5, 315.8, 51.4] | 52.6x50.0 | True | True | False | True | Kept |
| 26 | `bus` | 0.851 | 0.30 | [561.2, 71.1, 664.8, 82.4] | 103.6x11.3 | True | False | False | False | Kept |
| 27 | `bus` | 0.847 | 0.30 | [343.8, 456.2, 447.6, 467.7] | 103.8x11.5 | False | False | False | False | Kept |
| 28 | `generator` | 0.847 | 0.52 | [660.6, 186.9, 710.0, 236.7] | 49.4x49.8 | True | True | False | True | Kept |
| 29 | `bus` | 0.825 | 0.30 | [131.8, 456.0, 235.8, 467.7] | 104.0x11.8 | True | False | False | False | Kept |
| 30 | `bus` | 0.818 | 0.30 | [130.1, 248.3, 236.0, 259.9] | 105.9x11.6 | True | False | False | False | Kept |
| 31 | `bus` | 0.818 | 0.30 | [455.6, 455.5, 557.2, 467.4] | 101.6x11.8 | True | False | False | False | Kept |
| 32 | `generator` | 0.799 | 0.52 | [28.8, 586.7, 79.0, 636.7] | 50.2x50.0 | True | False | False | True | Kept |
| 33 | `load` | 0.795 | 0.35 | [410.6, 387.2, 420.3, 396.8] | 9.7x9.7 | True | True | False | False | Kept |
| 34 | `bus` | 0.785 | 0.30 | [563.4, 456.3, 666.5, 467.3] | 103.0x11.1 | True | False | False | False | Kept |
| 35 | `bus` | 0.779 | 0.30 | [560.5, 248.0, 667.4, 259.6] | 106.9x11.6 | True | False | False | False | Kept |
| 36 | `bus` | 0.752 | 0.30 | [240.3, 247.9, 341.6, 259.6] | 101.3x11.8 | True | False | False | False | Kept |
| 37 | `load` | 0.744 | 0.35 | [179.6, 701.4, 190.3, 712.0] | 10.7x10.6 | True | True | False | False | Kept |
| 38 | `load` | 0.731 | 0.35 | [279.2, 594.8, 290.4, 604.6] | 11.2x9.9 | True | True | False | False | Kept |
| 39 | `load` | 0.708 | 0.35 | [311.0, 279.3, 320.3, 289.8] | 9.3x10.5 | True | True | False | False | Kept |
| 40 | `load` | 0.696 | 0.35 | [518.2, 386.2, 528.1, 397.0] | 10.0x10.8 | True | True | False | False | Kept |
| 41 | `load` | 0.680 | 0.35 | [587.0, 279.3, 598.0, 289.4] | 11.0x10.1 | True | True | False | False | Kept |
| 42 | `load` | 0.668 | 0.35 | [47.8, 386.9, 59.2, 396.8] | 11.4x9.8 | True | True | False | False | Kept |
| 43 | `load` | 0.652 | 0.35 | [171.9, 594.2, 182.8, 604.7] | 11.0x10.5 | True | True | False | False | Kept |
| 44 | `load` | 0.602 | 0.35 | [365.5, 488.3, 374.4, 496.2] | 8.9x7.9 | True | True | False | False | Kept |
| 45 | `load` | 0.577 | 0.35 | [580.4, 102.9, 589.7, 112.2] | 9.4x9.3 | True | True | False | False | Kept |
| 46 | `load` | 0.573 | 0.35 | [718.6, 385.8, 728.2, 396.6] | 9.7x10.8 | True | True | False | False | Kept |
| 47 | `load` | 0.567 | 0.35 | [287.3, 186.5, 297.5, 196.5] | 10.1x9.9 | True | True | False | False | Kept |
| 48 | `load` | 0.564 | 0.35 | [311.6, 387.4, 320.1, 396.4] | 8.5x9.0 | True | True | False | False | Kept |
| 49 | `load` | 0.547 | 0.35 | [742.0, 103.0, 751.2, 111.6] | 9.2x8.6 | True | True | False | False | Kept |
| 50 | `load` | 0.515 | 0.35 | [418.4, 278.8, 428.1, 289.6] | 9.6x10.7 | True | True | False | False | Kept |
| 51 | `load` | 0.507 | 0.35 | [517.1, 647.8, 529.2, 658.8] | 12.1x11.0 | True | True | False | False | Kept |
| 52 | `load` | 0.496 | 0.35 | [893.6, 593.4, 907.7, 605.3] | 14.1x11.9 | True | True | False | False | Kept |
| 53 | `transformer` | 0.374 | 0.50 | [335.4, 470.1, 356.3, 497.6] | 20.9x27.6 | True | True | False | True | Dropped: conf 0.37 < thresh 0.50 |
| 54 | `load` | 0.329 | 0.35 | [179.3, 487.7, 189.9, 497.0] | 10.6x9.3 | True | True | False | False | Dropped: conf 0.33 < thresh 0.35 |
| 55 | `generator` | 0.310 | 0.52 | [420.2, 212.0, 440.1, 238.8] | 19.9x26.8 | False | True | False | True | Dropped: conf 0.31 < thresh 0.52 |
| 56 | `load` | 0.260 | 0.35 | [731.5, 212.0, 747.4, 223.9] | 15.9x11.9 | False | True | False | False | Dropped: conf 0.26 < thresh 0.35 |
| 57 | `load` | 0.239 | 0.35 | [284.6, 103.0, 293.5, 111.9] | 8.9x8.8 | True | True | False | False | Dropped: conf 0.24 < thresh 0.35 |
| 58 | `bus` | 0.185 | 0.30 | [410.7, 356.3, 447.8, 367.3] | 37.1x11.1 | True | False | False | False | Dropped: conf 0.18 < thresh 0.30 |
| 59 | `load` | 0.163 | 0.35 | [321.6, 318.9, 341.4, 327.4] | 19.8x8.5 | True | True | False | False | Dropped: conf 0.16 < thresh 0.35 |
| 60 | `load` | 0.160 | 0.35 | [203.2, 279.2, 212.8, 289.7] | 9.6x10.5 | True | True | False | False | Dropped: conf 0.16 < thresh 0.35 |
| 61 | `load` | 0.147 | 0.35 | [322.3, 318.7, 341.5, 346.2] | 19.2x27.5 | False | True | False | False | Dropped: conf 0.15 < thresh 0.35 |
| 62 | `transformer` | 0.137 | 0.50 | [730.6, 119.1, 763.6, 148.3] | 33.0x29.2 | False | True | False | True | Dropped: conf 0.14 < thresh 0.50 |
| 63 | `load` | 0.119 | 0.35 | [565.0, 606.5, 584.9, 614.4] | 19.8x7.9 | False | True | False | False | Dropped: conf 0.12 < thresh 0.35 |
| 64 | `generator` | 0.110 | 0.52 | [752.1, 318.8, 771.0, 347.7] | 18.9x28.9 | False | True | False | False | Dropped: conf 0.11 < thresh 0.52 |
| 65 | `load` | 0.091 | 0.35 | [42.4, 321.5, 61.1, 342.6] | 18.7x21.2 | False | True | False | False | Dropped: conf 0.09 < thresh 0.35 |
| 66 | `generator` | 0.079 | 0.52 | [720.8, 34.1, 739.9, 62.2] | 19.0x28.0 | False | True | False | True | Dropped: conf 0.08 < thresh 0.52 |
| 67 | `load` | 0.071 | 0.35 | [568.1, 606.4, 583.2, 637.1] | 15.1x30.7 | False | True | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 68 | `load` | 0.070 | 0.35 | [153.3, 212.2, 169.4, 228.0] | 16.1x15.8 | False | True | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 69 | `load` | 0.070 | 0.35 | [300.8, 527.2, 311.1, 557.0] | 10.3x29.9 | False | False | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 70 | `load` | 0.066 | 0.35 | [588.0, 483.7, 598.6, 498.9] | 10.6x15.2 | True | True | False | False | Dropped: conf 0.07 < thresh 0.35 |
| 71 | `load` | 0.065 | 0.35 | [700.2, 34.1, 716.6, 48.5] | 16.4x14.5 | True | True | False | False | Dropped: conf 0.06 < thresh 0.35 |
| 72 | `bus` | 0.060 | 0.30 | [620.0, 356.5, 663.2, 367.8] | 43.2x11.3 | True | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 73 | `load` | 0.057 | 0.35 | [731.2, 211.9, 747.9, 240.3] | 16.7x28.4 | False | True | False | True | Dropped: conf 0.06 < thresh 0.35 |
| 74 | `transformer` | 0.056 | 0.50 | [709.9, 34.1, 739.9, 63.3] | 30.1x29.2 | False | True | False | True | Dropped: conf 0.06 < thresh 0.50 |
| 75 | `bus` | 0.055 | 0.30 | [110.1, 564.3, 125.8, 575.8] | 15.7x11.5 | True | False | False | False | Dropped: conf 0.06 < thresh 0.30 |
| 76 | `load` | 0.051 | 0.35 | [135.5, 213.0, 146.1, 237.0] | 10.7x23.9 | False | True | False | False | Dropped: conf 0.05 < thresh 0.35 |
