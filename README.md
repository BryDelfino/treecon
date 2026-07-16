# TREECON:
## Description: <br>
A system for managing Falcata tree gall rust <i>(Uromycladium falcatarium)</i>. It has two edges: <br>
- <b>SCOUT</b>: The mobile edge meant for community, field use. It utilizes the built-in camera
for capturing observations. It also utilizes the built-in geolocator
to acquire the observation's latitude and longitude coordinates which are displayed on a spatial map.
The spatial map allows the users to load an expert's datasets to which they can see the plantation points,
their severity defined by Gall Rust Severity Index (GSI), and generate map layers that show the
gall rust's spread over the map (through ordinary Kriging) and its forecast (Cellular Automata).
- <b>COMMANDER</b>: The web dashboard meant for experts of the field. Experts have 
the option to upload their observations via upload, verify observations made by the SCOUT client, 
and receive vital information from the spatial map. The expert has the ability to upload their
datasets to be shown on the map. In addition, they have the option to make a dataset public (can be seen by anyone)
or private (just to the owner).
