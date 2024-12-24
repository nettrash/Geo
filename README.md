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

$$\frac{P} {P_0} = e^\frac{-M g h} {R T}$ $\rightarrow$ $\ln \frac{P} {P_0} = \frac{_M g h} {R T}$ $\rightarrow$ ${R T} \ln \frac{P} {P_0} = -{M g h}$ $\rightarrow$ $h = \frac{{R T} \ln \frac{P} {P_0}} {-{M g}}$$

Simplistically, you can write as: $$P_h = P_0 10^{-0.000052 h}$$  

$$P_h = P_0 10^{-0.000052 h}$ $\rightarrow$ $\frac{P_h} {P_0} = 10^{-0.000052 h}$ $\rightarrow$ $\lg \frac{P_h} {P_0} = {-0.000052 h}$ $\rightarrow$ $h = \frac{\lg \frac{P_h} {P_0}} {-0.000052}$ $\rightarrow$ $h = \frac{\ln \frac{P_0} {P_h}} {0.000052 \ln 10}$ $\rightarrow$ $h \approx \frac{\ln \frac{P_0} {P_h}} {0.00012}$$

$$lg x = \frac{\ln x} {ln 10}$$  

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

