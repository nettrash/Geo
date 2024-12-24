# GEO

![build](https://github.com/nettrash/Geo/actions/workflows/ios.yml/badge.svg)

## About  

Geo is an application for tracking current geographical characteristics, such as location (coordinates), altitude according to satellite readings and calculated by the current atmospheric pressure indicator.  

Additionally, information about current weather and geocoding data on the ground is available in the application.  

And the most interesting, the application saves the parameter data locally on the device, allowing you to watch their change over time in graphical form.  

## Calculation  

$$P=P_0 e^\frac{-M g h} {R T}$$

where $$P_0$$ pressure at sea level (Pa)  
$$P$$ is the pressure at height $$h$$ (Pa)  
$$M$$ - molar mass of dry air,  
$$M = 0.029 \frac{Kg} {mol}$$  
$$g$$ - acceleration of free fall,  
$$g = 9.81 \frac{m} {s^2}$$  
$$R$$ is the universal gas constant,  
$$T = 273.15 + t$$,  
$$T$$ - absolute air temperature $$K$$,  
$$t$$ - temperature in $$C$$
$$h$$ is the height m  

Convert the formula to calculate the height at a known pressure.    

![equation](http://latex.codecogs.com/gif.latex?%5Cfrac%7BP%7D%20%7BP_0%7D%20%3D%20e%5E%5Cfrac%7B-M%20g%20h%7D%20%7BR%20T%7D%24%20%24%5Crightarrow%24%20%24%5Cln%20%5Cfrac%7BP%7D%20%7BP_0%7D%20%3D%20%5Cfrac%7B_M%20g%20h%7D%20%7BR%20T%7D%24%20%24%5Crightarrow%24%20%24%7BR%20T%7D%20%5Cln%20%5Cfrac%7BP%7D%20%7BP_0%7D%20%3D%20-%7BM%20g%20h%7D%24%20%24%5Crightarrow%24%20%24h%20%3D%20%5Cfrac%7B%7BR%20T%7D%20%5Cln%20%5Cfrac%7BP%7D%20%7BP_0%7D%7D%20%7B-%7BM%20g%7D%7D)

Simplistically, you can write as: ![equation](http://latex.codecogs.com/gif.latex?P_h%20%3D%20P_0%2010%5E%7B-0.000052%20h%7D)  

![equation](http://latex.codecogs.com/gif.latex?P_h%20%3D%20P_0%2010%5E%7B-0.000052%20h%7D%24%20%24%5Crightarrow%24%20%24%5Cfrac%7BP_h%7D%20%7BP_0%7D%20%3D%2010%5E%7B-0.000052%20h%7D%24%20%24%5Crightarrow%24%20%24%5Clg%20%5Cfrac%7BP_h%7D%20%7BP_0%7D%20%3D%20%7B-0.000052%20h%7D%24%20%24%5Crightarrow%24%20%24h%20%3D%20%5Cfrac%7B%5Clg%20%5Cfrac%7BP_h%7D%20%7BP_0%7D%7D%20%7B-0.000052%7D%24%20%24%5Crightarrow%24%20%24h%20%3D%20%5Cfrac%7B%5Cln%20%5Cfrac%7BP_0%7D%20%7BP_h%7D%7D%20%7B0.000052%20%5Cln%2010%7D%24%20%24%5Crightarrow%24%20%24h%20%5Capprox%20%5Cfrac%7B%5Cln%20%5Cfrac%7BP_0%7D%20%7BP_h%7D%7D%20%7B0.00012%7D)

![equation](http://latex.codecogs.com/gif.latex?lg%20x%20%3D%20%5Cfrac%7B%5Cln%20x%7D%20%7Bln%2010%7D)  

![equation](http://latex.codecogs.com/gif.latex?%5Clog%20%5Cfrac%7Bx%7D%20%7By%7D%20%3D%20-%5Clog%20%5Cfrac%7By%7D%20%7Bx%7D)  

## Compass Points

| POINT | DEGREE FROM | DEGREE TO |
|-|-|-|
| NORD | 338 | 22 |
| NORD EAST | 23 | 67 |
| EAST | 68 | 112 |
| SOUTH EAST | 113 | 157 |
| SOUTH | 158 | 202 |
| SOUTH WEST | 203 | 247 |
| WEST | 248 | 292 |
| NORD WEST | 293 | 337 |

