#impetus intrinsic symbol
+             :  Addition
-             :  Substraction
*             :  Multiplication
/             :  Division
^             :  Exponentiation
&&            :  And
||            :  Or
==            :  Equality
!=            :  Inequality
<             :  Strictly less than
<=            :  Strictly greater than
>             :  Strictly greater than
>=            :  Greater than or equal

X             :  Along x direction
Y             :  Along y direction
Z             :  Along z direction
RX            :  Round X direction
RY            :  Round Y direction
RZ            :  Round Z direction
RXY           :  Round XY direction
RXZ           :  Round XZ direction
RYZ           :  Round YZ direction
RXYZ          :  Round XYZ direction

A             :  acceleration
V             :  velocity
D             :  displacement

#impetus intrinsic variable
pi            :  3.141592653589793...
dt            :  Time step
t             :  Current simulation time
term          :  Termination time
R             :  Radius
theta         :  Angle
X             :  Initial x-coordinate  
Y             :  Initial y-coordinate  
Z             :  Initial z-coordinate  
x             :  Current x-coordinate 
y             :  Current y-coordinate 
z             :  Current z-coordinate 
vx            :  Local velocity in x-direction
vy            :  Local velocity in y-direction
vz            :  Local velocity in z-direction
xnorm         :  x-component of local surface normal direction
ynorm         :  y-component of local surface normal direction
znorm         :  z-component of local surface normal direction
epsp          :  Equivalent plastic strain
sigy0         :  Initial yield stress
dmg           :  Damage
amax          :  Max acceleration
eint          :  Specific internal energy
pres          :  Contact pressure or hydrostatic pressure in material (LOAD_PRESSURE)
vtang         :  Relative tangential sliding velocity (for use with CONTACT)
dnorm         :  Spring elongation in CONNECTOR_SPRING
vnorm         :  Local velocity in the normal direction to the surface of the structure or rate of elongation in CONNECTOR_SPRING
wi            :  Returns the total internal energy in the model
we            :  Returns the total elastic energy in the model
wk            :  Returns the total kinetic energy in the model
rnd           :  Returns a random number between 0 and 1. The seed to the random number 
                 generator can be defined as deterministic (default) or random (see RANDOM_NUMBER_GENERATOR_SEED)
T             :  Temperature
vmax_cfd      :  Max velocity in cfd domain (see CFD_DOMAIN)
wflux_cfd     :  Energy flux across CFD domain boundary
sph_jet       :  SPH jet tip coordinate
sc_jet(1)     :  Return jet length
sc_jet(2)     :  Return jet tip velocity
sc_jet(3)     :  Return axial momentum
sc_jet(4)     :  Return radial momentum
sc_jet(5)     :  Return max radial momentum
sc_jet(6)     :  Return time since peak radial momentum

bc            :  Boundary condition
cid           :  Curve ID
coid          :  Command ID
csysid        :  Coordinate system ID
did           :  Damage command ID
direc         :  Direction
enid          :  Entity ID
entype        :  Entity type
eosid         :  Equation-of-state ID
fid           :  Function ID
gid           :  Geometry ID
mfid          :  Merge failure ID
mid           :  Material ID
nid           :  Node ID
nsid          :  Node set ID
pid           :  Part ID
setid         :  Set ID
thpid         :  Thermal property ID
tabid         :  Table ID
sf            :  Scale factor
t_beg         :  Command activation time
t_end         :  Command deactivation time
tol           :  Tolerance


#impetus intrinsic function
sin(x)        :  Trigonometric sine function (degrees)
cos(x)        :  Trigonometric cosine function (degrees)
tan(x         :  Trigonometric tangent function (degrees)
asin(x)       :  Trigonometric arcsine function (degrees)
atan(x)       :  Trigonometric arctangent function (degrees)
tanh(x)       :  Hyperbolic tangent function (degrees)
sinr(x)       :  Trigonometric sine function (radians)
cosr(x)       :  Trigonometric cosine function (radians)
tanr(x)       :  Trigonometric tangent function (radians)
asinr(x)      :  Trigonometric arcsine function (radians)
acosr(x)      :  Trigonometric arccosine function (radians)
atanr(x       :  Trigonometric arctangent function (radians)
exp(x)        :  Exponential function
ln(x)         :  Natural logarithm
log(x)        :  Natural logarithm, identical to ln(x)
log10(x)      :  Logarithm to base 10
sqrt(x)       :  Square root
mod(a, b)     :  Modulo operation, returning the remainder of division a/b
abs(x)        :  Absolute value
sign(x)       :  sign(x) = -1 if x < 0;  sign(x) = 1 if x ≥ 0
floor(x)      :  Rounds to nearest integer below or equal to x
ceil(x)       :  Rounds to nearest integer above or equal to x
round(x)      :  Rounds to nearest integer
d(i, j)       :  Kronecker delta. The function returns 1 if the variables are equal, and 0 otherwise
H(x)          :  Heaviside Step function. H(x) = 0 if x < 0; H(x) = 1 if x ≥ 0
erf(x)        :  Gauss error function
min( x1, x2, x3)        :  Min value of arguments. This function can take up to 10 arguments, min(x1, x2, ..., xn)
max( x1, x2, x3)        :  Max value of arguments. This function can take up to 10 arguments, min(x1, x2, ..., xn)
smooth_d(dmax, t0, t1)  :  A displacement defined as smooth_d(disp, t0, t1) is smoothly ramped up from 0 to disp 
                           between time t0 and t1. The input does not have to be based on parameters; direct input 
                           works as well. Other quantities, such as pressure, temperature, force, e.t.c. can be 
                           used as input instead of displacement in smooth_d()
smooth_v(dmax, t0, t1)  :  Smooth velocity function that is obtained by differentiating smooth_d() with respect to time
smooth_a(dmax, t0, t1)  :  Smooth acceleration function that is obtained by differentiating smooth_v with respect to time
norminv(μ, σ, P, cap)   :  (Optional) Normal distribution quantile (inverse cumulative distribution function). 
                           The function returns a value in a normal distribution. Required input is the median value μ, 
                           standard σ and a cumulative point in the distribution 0 < P < 1 (typically a random number). 
                           cap is optional and limits the deviation from μ (max number of standard deviations)
lognorminv(μ, σ, P, cap):  Log-normal distribution quantile (inverse cumulative distribution function). The function 
                           returns a value in a log-normal distribution. exp( μ) is the median value in the distribution, 
                           σ is the standard deviation of the variable's natural logarithm and 0 < P < 1 is a cumulative 
                           point in the distribution (typically a random number). cap is optional and limits the deviation 
                           from μ (max number of standard deviations)
crv(cid, x)             :  Returns the ordinate of curve cid at abscissa x. cid = Curve id and x = Abscissa
fcn(fid, x)             :  Returns a curve or function value. fid = FUNCTION id, x = Abscissa (Optioanl). 
dfcn(fid)               :  Time derivative of fcn(fid).  
table(tabid, rid, cid)  :  Returns the value at row and column (rid, cid) of table tabid. tabid: Table ID, rid: Row number, cid: Column number 
path(pid, ξ, 1)         :  x-coordinate at relative position ξ along path
path(pid, ξ, 2)         :  y-coordinate at relative position ξ along path
path(pid, ξ, 3)         :  z-coordinate at relative position ξ along path
xn(nid)                 :  Returns the x-coordinate of nid (node id)
yn(nid)                 :  Returns the y-coordinate of nid (node id)
zn(nid)                 :  Returns the z-coordinate of nid (node id)
vxn(nid)                :  Returns the x-velocity of nid (node id)
vyn(nid)                :  Returns the y-velocity of nid (node id)
vzn(nid)                :  Returns the z-velocity of nid (node id)
vn(nid)                 :  Returns the resultant velocity of nid (node id)
dist_surf(xn(nid), yn(nid), zn(nid)) : Returns the distance to material surface 

	dxp(pid)                :  Returns the x-displacement of pid (part id)
	dyp(pid)                :  Returns the y-displacement of pid (part id)
	dzp(pid)                :  Returns the z-displacement of pid (part id)
	vxp(pid)                :  Returns the x-velocity of pid (part id)
	vyp(pid)                :  Returns the y-velocity of pid (part id)
	vzp(pid)                :  Returns the z-velocity of pid (part id)
	rxp(pid)                :  Returns the rotation around x-axis of pid (part id)
	ryp(pid)                :  Returns the rotation around y-axis of pid (part id)
	rzp(pid)                :  Returns the rotation around z-axis of pid (part id)
	xmaxp(pid, xn, yn, zn)  :  Returns the maximum coordinate of part measure from (0, 0, 0) in direction (xn, yn, zn)
	wip(pid)                :  Returns the internal energy of pid (part id)
	wkp(pid)                :  Returns the kinetic energy of pid (part id)
	mpp(pid)                :  Returns the part mass (physical) of pid (part id)
	mpa(pid)                :  Returns the part mass (added) of pid (part id)
	mpa(pid)                :  Returns the part mass (added) of pid (part id)
dmgp(pid)               :  Returns max damage of pid (part id)
epsp_part(pid, 0)       :  Largest effective plastic strain
epsp_part(pid, 1)       :  x-coordinate of integration point with largest effective plastic strain
epsp_part(pid, 2)       :  y-coordinate of integration point with largest effective plastic strain
epsp_part(pid, 3)       :  z-coordinate of integration point with largest effective plastic strain
pres_part(pid, 0)       :  Highest pressure
pres_part(pid, 1)       :  x-coordinate of integration point with highest pressure
pres_part(pid, 2)       :  y-coordinate of integration point with highest pressure
pres_part(pid, 3)       :  z-coordinate of integration point with highest pressure
rate_part(pid, 0)       :  Highest strain rate
rate_part(pid, 1)       :  x-coordinate of integration point with highest strain rate
rate_part(pid, 2)       :  y-coordinate of integration point with highest strain rate
rate_part(pid, 3)       :  z-coordinate of integration point with highest strain rate
wd_part(pid, 0)         :  Initial energy in explosive charge 
wd_part(pid, 1)         :  Current (remaining) energy in explosive charge 
wd_part(pid, 2)         :  Current energy release rate
wd_part(pid, 3)         :  Time elapsed since energy release ceased
cog_part(pid, 1)        :  x-coordinate at center of gravity
cog_part(pid, 2)        :  y-coordinate at center of gravity
cog_part(pid, 3)        :  z-coordinate at center of gravity
vmax_p(pid)             :  Returns max velocity of pid

xs_old(sid)             :  Returns the x-coordinate (initial) of sid (sensor id)
ys_old(sid)             :  Returns the y-coordinate (initial) of sid (sensor id)
zs_old(sid)             :  Returns the z-coordinate (initial) of sid (sensor id)
xs(sid)                 :  Returns the x-coordinate (current) of sid (sensor id)
ys(sid)                 :  Returns the y-coordinate (current) of sid (sensor id)
zs(sid)                 :  Returns the z-coordinate (current) of sid (sensor id)
dxs(sid)                :  Returns the x-displacement of sid (sensor id)
dys(sid)                :  Returns the y-displacement of sid (sensor id)
dzs(sid)                :  Returns the z-displacement of sid (sensor id)
vxs(sid)                :  Returns the x-velocity of sid (sensor id)
vys(sid)                :  Returns the y-velocity of sid (sensor id)
vzs(sid)                :  Returns the z-velocity of sid (sensor id)
axs(sid)                :  Returns the x-acceleration of sid (sensor id)
ays(sid)                :  Returns the y-acceleration of sid (sensor id)
azs(sid)                :  Returns the z-acceleration of sid (sensor id)
epsps(sid)              :  Returns the effective plastic strain of sid (sensor id)
depsps(sid)             :  Returns the effective plastic strain increment of sid (sensor id)
epsxxs(sid)             :  Returns the X-strain of sid (sensor id)
epsyys(sid)             :  Returns the Y-strain of sid (sensor id)
epszzs(sid)             :  Returns the Z-strain of sid (sensor id)
dmgs(sid)               :  Returns the damage of sid (sensor id)
Ts(sid)                 :  Returns the temperature of sid (sensor id)
ps(sid)                 :  Returns the pressure of sid (sensor id)
sps(sid)                :  Returns the surface pressure of sid (sensor id)
sigxxs(sid)             :  Returns the X-stress of sid (sensor id)
sigyys(sid)             :  Returns the Y-stress of sid (sensor id)
sigzzs(sid)             :  Returns the z-stress of sid (sensor id)
sig1s(sid)              :  Returns the first principal stress of sid (sensor id)
sgps(sid)               :  Returns the gas pressure of sid (sensor id)
triaxs(sid)             :  Returns the triaxiality of sid (sensor id)
lodes(sid)              :  Returns the lode angle ( -30° ≤ θ ≤ 30°) of sid (sensor id)
nlodes(sid)             :  Returns the normalized lode angle ( -1 ≤ θ ≤ 1) of sid (sensor id)

fxc(cid)                :  Returns the total contact force in x-direction of cid (contact id)
fyc(cid)                :  Returns the total contact force in y-direction of cid (contact id)
fzc(cid)                :  Returns the total contact force in z-direction of cid (contact id)
fc(cid)                 :  Returns the resultant contact force of cid (contact id)  

fxr(bcid)               :  Returns the reaction force, x-direction of bcid (boundary constrain id)
fyr(bcid)               :  Returns the reaction force, y-direction of bcid (boundary constrain id)
fzr(bcid)               :  Returns the reaction force, z-direction of bcid (boundary constrain id)
fr(bcid)                :  Returns the reaction force, resultant of bcid (boundary constrain id)
txr(bcid)               :  Returns the torque around x-axis of bcid (boundary constrain id)
tyr(bcid)               :  Returns the torque around y-axis of bcid (boundary constrain id)
tzr(bcid)               :  Returns the torque around z-axis of bcid (boundary constrain id)
tr(bcid)                :  Returns the resultant torque of bcid (boundary constrain id)   

vol_geo(gid, tol, dir)  :  Volume enclosed by the element faces in geometry gid. tol is 
                           an optional dimensionless tolerance. Gaps in the surface will 
                           result in errors. If the estimated (relative) error is larger 
                           than tol then the function will return 0 (zero). The optional 
                           parameter dir is used to avoid the volume calculation in specific 
                           global directions (divergence theorem). This is necessary if the 
                           control volume is located on symmetry planes. The global x-direction 
                           is avoided if dir = 1, 4 or 6, the global y-direction is avoided 
                           if dir = 2, 4 or 5 and the global z-direction is avoided if 
                           dir = 3, 5 or 6
vol_geo0(gid, tol, dir) : Initial volume enclosed by the element faces in geometry gid. 
                          The function arguments are the same as for function vol_geo()       
       
volfs(setid)      :  Returns the volume enclosed by face set setid  

fxj(jid)          :  Returns the force in x-direction of jid (joint id)
fyj(jid)          :  Returns the force in y-direction of jid (joint id)
fzj(jid)          :  Returns the force in z-direction of jid (joint id)
txj(jid)          :  Returns the torque around x-axis of jid (joint id)
tyj(jid)          :  Returns the torque around y-axis of jid (joint id)
tzj(jid)          :  Returns the torque around z-axis of jid (joint id)
rxj(jid)          :  Returns the rotation around x-axis of jid (joint id)
ryj(jid)          :  Returns the rotation around y-axis of jid (joint id)
rzj(jid)          :  Returns the rotation around z-axis of jid (joint id)
sxj(jid)          :  Returns the spin around x-axis of jid (joint id)
syxj(jid)         :  Returns the spin around y-axis of jid (joint id)
szj(jid)          :  Returns the spin around z-axis of jid (joint id)     

vmax_dp(sid, 0)   : Max velocity
vmax_dp(sid, 1)   : Max velocity in x-direction
vmax_dp(sid, 2)   : Max velocity in y-direction
vmax_dp(sid, 3)   : Max velocity in z-direction
