; ======================================================================
; Modèle Linkscape - Janvier 2025 (NetLogo 6.4)
; ======================================================================
; Cadre général :
;   - Simulation multi-agents spatialisée (turtles) sur une grille (patches).
;   - Réseau social dynamique représenté par des liens (links) entre turtles.
;   - Ressource environnementale locale (patches) pouvant former des "attracteurs"
;     exploités par les agents.
;   - Mécanisme de changement de régime ("crise") altérant les paramètres du milieu.
;   - Instrumentation : export tick-par-tick des métriques (CSV) pour analyse externe.
; ======================================================================

extensions [table csv]  ; 'table' pour structures clé-valeur ; 'csv' pour faciliter l'export de séries.

; ----------------------------------------------------------------------
; 1) ÉTAT DU MILIEU (patches)
; ----------------------------------------------------------------------
patches-own [
  attractor?  ; Indicateur booléen : le patch est-il un attracteur (zone exploitable / visible) ?
  ressource   ; Stock de ressource local ; décroît par consommation et croît via la procédure de régénération.
]

; ----------------------------------------------------------------------
; 2) ÉTAT DES AGENTS (turtles)
; ----------------------------------------------------------------------
turtles-own [
  spice           ; Énergie individuelle : conditionne survie, activité et reproduction.
  max-spice       ; Paramètre individuel (seuil) utilisé pour déclencher la division.
  target          ; Cible courante (références de type patch) ou nobody si absence de cible.
  target?         ; Booléen : l’agent considère-t-il disposer d’une cible exploitable ?
  p-association   ; Propension individuelle à créer des liens (probabilité de connexion).
  cap-association ; Capacité individuelle : borne supérieure (souple) du nombre de voisins.
]

; ----------------------------------------------------------------------
; 3) VARIABLES GLOBALES : mesures, logging, et cohérence des runs
; ----------------------------------------------------------------------
globals [
  values           ; Tampon pour itérations sur valeurs de tables (mesure entropie).
  goods            ; Compteur global de biens produits (ici : nombre total d’actes de consommation).
  n-attractors     ; Variable déclarée (utilisée par logging via n_attr) ; indicateur de densité d’attracteurs.
  entropy          ; Entropie de Shannon de la distribution des degrés (hétérogénéité du réseau).
  crisis?          ; Booléen : régime de crise actif ou non.
  sum-p            ; Somme des p-association (pour calculer avg-p).
  sum-max-spice    ; Somme des max-spice (pour calculer avg-max-spice).
  avg-p            ; Moyenne des propensions à s’associer.
  avg-links        ; Degré moyen : nombre de liens / nombre d’agents.
  avg-max-spice    ; Moyenne des seuils max-spice.
  adjacency-table  ; Table : who → liste des who des voisins ; capture du graphe à un tick donné.
  adjacency-list   ; Version linéarisée de l’adjacence (plus simple à inspecter/exporter).

  ; --- PARAMS SNAPSHOT (cohérence run) ---
  run-wealth          ; Valeur de wealth figée au démarrage (utile si settings modifie wealth ensuite).
  run-growth-rate     ; Valeur de growth-rate figée au démarrage.
  run-max-attractors  ; Valeur de max-attractors figée au démarrage.
]


; ======================================================================
; 1) INITIALISATION DU SYSTÈME
; ======================================================================
; Étapes :
;   - Remise à zéro de l’état.
;   - Création des agents avec traits initiaux (spice, max-spice, propension/capacité de liens).
;   - Initialisation des patches (ressource aléatoire, attracteurs désactivés).
;   - Initialisation de l’instrumentation (fichier CSV).
;   - Activation éventuelle de règles de régime (check-crisis) au tick initial.

to setup
  clear-all
  set-default-shape turtles "circle"

  create-turtles num-nodes [
    set color white
    set spice initial-spice
    set max-spice initial-spice
    set target? false
    set target nobody
    set size 0.3
    set p-association random-float initial-p
    set cap-association random-float initial-cap
    setxy random-pxcor random-pycor
  ]

  set goods 0
  set crisis? false

  setup-patches
  reset-ticks
  check-crisis
end

to setup-patches
  ask patches [
    set attractor? false
    set ressource random wealth
  ]
end

; ======================================================================
; 2) BOUCLE PRINCIPALE (DYNAMIQUE TEMPORELLE)
; ======================================================================
; Ordonnancement par tick :
;   (i)   arrêt conditionnel si time-limit atteint
;   (ii)  mise à jour du régime (check-crisis)
;   (iii) phase agents (contrôle des liens, ciblage, connexion, action, mutation, reproduction, métabolisme)
;   (iv)  phase environnement (grow)
;   (v)   agrégation d’indicateurs + mesures réseau
;   (vi)  export des métriques (CSV)
;   (vii) incrément du tick

to go
  if time-limit != 0 and ticks = time-limit [ export-plots stop ]

  check-crisis

  set sum-p 0
  set sum-max-spice 0

  if not any? turtles [ stop ]

  ask turtles [

    ; --- (1) Régulation de la densité relationnelle ---
    ; Un dépassement de la capacité individuelle entraîne la suppression itérative de liens aléatoires.
    let diff count link-neighbors - cap-association
    if diff > 0 [
      while [diff > 0] [
        ask one-of my-links [ die ]
        set diff diff - 1
      ]
    ]

    ; --- (2) Ciblage informé par le réseau ---
    update_target

    ; --- (3) Formation de liens sociaux ---
    connect

    ; --- (4) Politique d’action (priorité : survie > exploitation > déplacement ciblé > errance) ---
    (ifelse
      spice < 1 [ die ]
      [ attractor? ] of patch-here = true [ eat ]
      target? = true [ go_to_target ]
      [
        rt random wander
        lt random wander
        jump speed
      ]
    )

    ; --- (5) Variation individuelle ---
    mutate

    ; --- (6) Reproduction asexuée ---
    divide

    ; --- (7) Métabolisme ---
    set spice spice - 2

    ; --- (8) Accumulation pour statistiques ---
    set sum-p sum-p + p-association
    set sum-max-spice sum-max-spice + max-spice
  ]

  ; Phase environnementale
  grow

  ; Agrégation
  let n-turtles count turtles
  if n-turtles > 0 [
    set avg-p sum-p / n-turtles
    set avg-links count links / n-turtles
    set avg-max-spice sum-max-spice / n-turtles
  ]

  ; Mesures réseau et capture de structure
  get-network-entropy
  get-adjacency-list

  tick
end

; ======================================================================
; 3) CHANGEMENTS DE RÉGIME / CRISES
; ======================================================================
; Mécanisme :
;   - 'switch' : bascule périodique entre deux régimes (concentration ↔ dispersion) et activation de crisis?.
;   - 'minor-switch' : oscillation de neutral (si crise inactive).
;   - 'settings' : réécriture automatique de paramètres globaux (wealth, growth-rate, max-attractors)
;                 en fonction du régime courant.
;   - choc environnemental : remise à niveau des ressources et suppression des attracteurs selon des échéances.

to check-crisis
  (ifelse

    switch != 0 and ticks != 0 and remainder ticks switch = 0 [
      ifelse concentration = true
        [ set dispersion true set concentration false ]
        [ set concentration true set dispersion false ]

      set neutral false
      set crisis? true
    ]

    minor-switch != 0 and ticks != 0 and remainder ticks minor-switch = 0 and crisis? = false [
      ifelse neutral = true [ set neutral false ] [ set neutral true ]
    ]
  )

  if ticks != crisis-duration and crisis-duration != 0 and remainder ticks minor-switch = crisis-duration and crisis? = false [
    ifelse neutral = true [ set neutral false ] [ set neutral true ]
  ]

  if settings = true [
    ; x approxime la surface (nombre de patches) à partir des bornes spatiales
    let x max-pxcor * max-pycor * 4
    (
      ifelse
        neutral = true [
          set growth-rate 50
          set wealth 5000
          set max-attractors int (x / 20)
        ]
        concentration = true [
          set growth-rate 50
          set wealth 10000
          set max-attractors int (x / 50)
        ]
        dispersion = true [
          set growth-rate 50
          set wealth 200
          set max-attractors int x
        ]
        [
          set growth-rate 50
          set wealth 10000
          set max-attractors x
        ]
    )
  ]

  if (switch != 0 and ticks != 0 and remainder ticks switch = 0)
     or (ticks != crisis-duration and crisis-duration != 0 and remainder ticks switch = crisis-duration) [

    ask patches [
      set ressource wealth * 0.99
      if ressource < wealth [
        set pcolor black
        set attractor? false
      ]
    ]
  ]
end

; ======================================================================
; 4) CIBLAGE (DIFFUSION D’INFORMATION PAR LE RÉSEAU)
; ======================================================================
; Le ciblage dépend de l’existence, dans le voisinage social (link-neighbors),
; d’agents situés sur des patches attracteurs. Une cible est représentée par un patch.
; Si la condition d’accessibilité sociale disparaît, la cible est invalidée.

to update_target
  if target? = true and not any? link-neighbors with [ attractor? ] = true [
    set target? false
    set target nobody
  ]

  (ifelse
    target? = false and any? link-neighbors with [ attractor? ] = true [
      set target [target] of one-of link-neighbors with [ attractor? = true ]
      set target? true
    ]
    [
      set target? false
      set target nobody
    ]
  )
end

; ======================================================================
; 5) FORMATION DES LIENS (RÉSEAU SOCIAL)
; ======================================================================
; Schéma de connexion pair-à-pair :
;   - un lien est créé entre deux agents si chacun dispose de "capacité" restante,
;     et si les deux tirages probabilistes (p-association de chaque côté) réussissent.
; Cette implémentation effectue une exploration exhaustive des autres turtles.

to connect
  foreach [self] of other turtles [
    t ->
    if count link-neighbors < cap-association
       and [ count link-neighbors ] of t < [ cap-association ] of t [

      if random-float 1 < p-association
         and random-float 1 < [ p-association ] of t [
        create-link-with t
      ]
    ]
  ]
end

; ======================================================================
; 6) DÉPLACEMENT VERS LA CIBLE
; ======================================================================
; Déplacement dirigé :
;   - orientation vers les coordonnées du patch cible (facexy),
;   - translation de longueur 'speed' (jump).
; La condition 'target != nobody' garantit l’existence d’une référence de patch.

to go_to_target
  if target != nobody [
    facexy [ pxcor ] of target [ pycor ] of target
    jump speed
  ]
end

; ======================================================================
; 7) CONSOMMATION SUR ATTRACTEUR
; ======================================================================
; Effets :
;   - ancrage de la cible sur le patch courant,
;   - décrément de la ressource locale,
;   - extinction de l’attracteur si la ressource atteint un seuil bas,
;   - gain individuel (spice) et incrément du compteur global (goods).

to eat
  set target? true
  set target patch-here

  ask patch-here [
    set ressource ressource - 1
    if ressource < 1 [
      set pcolor black
      set attractor? false
    ]
  ]

  set spice spice + 4
  set goods goods + 1
end

; ======================================================================
; 8) MUTATION (DÉRIVE DES TRAITS SOCIAUX)
; ======================================================================
; À chaque tick, avec probabilité mutation-rate :
;   - mortalité aléatoire (bad-mutation),
;   - sinon, mutation conjointe :
;       * p-association se déplace par pas de ±0.001 (bornage supérieur à 0.999 côté augmentation),
;       * cap-association se déplace par pas de ±0.1 (bornage inférieur à 0.1 côté diminution).
; La mutation couple donc propension et capacité d’association.

to mutate
  if random-float 1 < mutation-rate [

    if random-float 1 < bad-mutation [ die ]

    ifelse 0.5 < random-float 1 [
      if p-association < 0.999 [ set p-association p-association + 0.001 ]
      set cap-association cap-association + 0.1
    ][
      set p-association p-association - 0.001
      if cap-association > 0.1 [ set cap-association cap-association - 0.1 ]
    ]
  ]
end

; ======================================================================
; 9) REPRODUCTION / DIVISION
; ======================================================================
; Condition :
;   - division asexuée si spice > 2 * max-spice.
; Effets :
;   - création d’un clone (hatch 1) avec réinitialisations locales,
;   - redistribution partielle d’énergie.
; Le clone hérite des variables non réécrites (dont les traits sociaux).

to divide
  if spice > 2 * max-spice [
    hatch 1 [
      set color white
      set spice max-spice
      set target? false
      set target nobody
      set size 0.3
    ]
    set spice spice - initial-spice
  ]
end

; ======================================================================
; 10) DYNAMIQUE ENVIRONNEMENTALE (RÉGÉNÉRATION + ÉMERGENCE D’ATTRACTEURS)
; ======================================================================
; Tant que le nombre d’attracteurs est inférieur à max-attractors :
;   - les patches non-attracteurs se rechargent stochastiquement jusqu’à wealth,
;   - dès que ressource atteint wealth, le patch peut devenir attracteur (couleur rouge).
; Enfin, un bornage supérieur impose ressource ≤ wealth.

to grow
  if growth-rate > 0 and count patches with [ attractor? = true ] < max-attractors [
    ask patches with [ attractor? = false ] [
      ifelse ressource < wealth [
        set ressource ressource + random wealth * growth-rate / 10000
      ][
        if count patches with [ attractor? = true ] < max-attractors [
          set attractor? true
          set pcolor red
        ]
      ]
    ]
  ]

  ask patches [
    if ressource > wealth [ set ressource wealth ]
  ]
end

; ======================================================================
; 11) MESURE D’ENTROPIE DU RÉSEAU (DISTRIBUTION DES DEGRÉS)
; ======================================================================
; Objectif :
;   - construire la distribution des degrés k = 0..(n_turtles-1),
;   - calculer l’entropie de Shannon H = - Σ p(k) log2 p(k),
;     où p(k) est la proportion d’agents ayant exactement k voisins.
; Cette mesure caractérise la diversité des connectivités (homogène vs hétérogène).

to get-network-entropy
  let n_turtles count turtles
  if n_turtles = 0 [ set entropy 0 stop ]

  let links-table table:make
  let k 0
  let kmax (n_turtles - 1)

  while [k <= kmax] [
    table:put links-table k (count turtles with [count link-neighbors = k])
    set k k + 1
  ]

  set entropy 0
  foreach table:values links-table [
    c ->
    if c > 0 [
      let p (c / n_turtles)
      set entropy entropy - (p * log p 2)
    ]
  ]
end

; ======================================================================
; 12) CAPTURE DE LA STRUCTURE : LISTE D’ADJACENCE À UN TICK DONNÉ
; ======================================================================
; À l’instant adjacency-step :
;   - construction d’une table associant chaque identifiant who à la liste des voisins (who),
;   - conversion en liste linéaire adjacency-list (format sentence) pour inspection rapide.
; Cette capture sert typiquement à exporter ou analyser la topologie à un instant précis.

to get-adjacency-list
  if adjacency-step != 0 and ticks = adjacency-step [
    set adjacency-table table:make
    set adjacency-list []

    foreach [self] of turtles [
      t ->
      table:put adjacency-table [who] of t [who] of [link-neighbors] of t
    ]

    let index 0
    while [index < length table:keys adjacency-table] [
      let element1 item index table:keys adjacency-table
      let element2 item index table:values adjacency-table
      set adjacency-list lput (sentence element1 element2) adjacency-list
      set index index + 1
    ]

    show adjacency-list
  ]
end

; ======================================================================
; 13) EXPORT DES PLOTS (CSV)
; ======================================================================
; Exporte des plots NetLogo (interface) au format CSV, avec identifiant aléatoire
; et encodage d’un sous-ensemble de paramètres dans le nom pour faciliter la collecte.

to export-plots
  let id random-float 1.0

  export-plot "Harvesting"
    (word "results/" id "_" dispersion "_" minor-switch "_harvesting.csv")

  export-plot "number of turtles"
    (word "results/" id "_" dispersion "_" minor-switch "_turtles.csv")

  export-plot "average p"
    (word "results/" id "_" dispersion "_" minor-switch "_turtles.csv")

  export-plot "average number of associations"
    (word "results/" id "_" dispersion "_" minor-switch "_associations.csv")
end
@#$#@#$#@
GRAPHICS-WINDOW
536
10
1145
620
-1
-1
54.64
1
10
1
1
1
0
0
0
1
-5
5
-5
5
1
1
1
ticks
40.0

INPUTBOX
7
10
83
70
num-nodes
20.0
1
0
Number

BUTTON
326
503
389
536
go
go
T
1
T
OBSERVER
NIL
G
NIL
NIL
1

BUTTON
402
503
468
536
setup
setup
NIL
1
T
OBSERVER
NIL
S
NIL
NIL
1

INPUTBOX
96
11
162
71
wander
90.0
1
0
Number

INPUTBOX
7
81
81
141
sight
0.0
1
0
Number

INPUTBOX
173
11
253
71
initial-spice
3000.0
1
0
Number

PLOT
1191
11
1414
178
Harvesting
Time
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"goods" 1.0 0 -2674135 true "" "plot goods"

PLOT
1192
185
1415
354
number of turtles
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"alive" 1.0 0 -2674135 true "" "plot count turtles"

SLIDER
4
159
467
192
growth-rate
growth-rate
1
500
50.0
1
1
NIL
HORIZONTAL

INPUTBOX
356
12
432
72
initial-p
0.0
1
0
Number

INPUTBOX
266
12
343
72
initial-cap
1.0
1
0
Number

INPUTBOX
94
83
190
143
mutation-rate
1.0
1
0
Number

SLIDER
4
196
467
229
wealth
wealth
50
10000
10000.0
1
1
NIL
HORIZONTAL

SLIDER
4
234
466
267
max-attractors
max-attractors
1
400
2.0
1
1
NIL
HORIZONTAL

MONITOR
7
497
190
542
NIL
values
17
1
11

PLOT
243
331
470
488
average number of associations
NIL
NIL
0.0
10.0
0.0
3.0
true
false
"" ""
PENS
"n association" 1.0 0 -16777216 true "" "plot avg-links"

MONITOR
193
497
307
542
network entropy
entropy
17
1
11

PLOT
6
331
235
488
average p
NIL
NIL
0.0
10.0
0.0
0.01
true
false
"" ""
PENS
"default" 1.0 0 -16777216 true "" "plot avg-p"

SWITCH
199
277
324
310
concentration
concentration
0
1
-1000

SWITCH
5
277
97
310
settings
settings
0
1
-1000

SWITCH
323
277
429
310
dispersion
dispersion
1
1
-1000

INPUTBOX
197
84
300
144
bad-mutation
0.0
1
0
Number

INPUTBOX
311
85
364
145
speed
0.1
1
0
Number

INPUTBOX
314
555
415
615
switch
0.0
1
0
Number

INPUTBOX
6
555
109
615
adjacency-step
0.0
1
0
Number

INPUTBOX
210
556
312
616
crisis-duration
0.0
1
0
Number

INPUTBOX
112
555
208
615
minor-switch
0.0
1
0
Number

INPUTBOX
418
555
499
615
time-limit
10000.0
1
0
Number

SWITCH
97
277
200
310
neutral
neutral
1
1
-1000

@#$#@#$#@
## NETWORK EVOLUTION
## WHAT IS IT?
This model explores the evolution of a network of agents in a common pool resource management context. Agents aim to survive by consuming spice scattered throughout the environment. According to the exploration-exploitation dilemma, balancing the exploration of the environment and the exploitation of known resources is key for a community to thrive. The central question is: what is the most beneficial ratio between exploration and exploitation for a group of agents, given the distribution of spice in the environment?

To address this question, we track the structure of the network of agents, where two linked agents are considered neighbors. Neighbors can and will communicate with each other if they discover spice. An agent that hasn’t found spice will move toward a neighbor who has, if such a neighbor exists. Otherwise, the agent will move randomly until it either finds spice or dies.

In this model, a highly connected network of agents exhibits strong exploitative behavior, while a sparsely connected network explores its environment more intensively. At each time step, each agent loses a fixed amount of spice and will die if their spice level reaches zero. Agents can also adjust their connectivity (i.e., their probability of forming links with other agents) with a fixed mutation probability. Additionally, they can duplicate themselves if they accumulate enough spice, surpassing a fixed threshold.

Intuitively, we hypothesize that in an environment with a concentrated distribution of spice, high connectivity would be advantageous, as communication is critical for locating and exploiting topographically rare rewards. Conversely, in an environment with a sparse distribution of spice, lower connectivity would be favored. This is because communication often involves moving toward neighbors to share spice, whereas the absence of communication increases the likelihood of randomly stumbling upon spice.

## HOW IT WORKS
Below are the key components and processes of the model:

1. **Agents:**
   - Turtles represent nodes that gather resources and interact with one another.
   - Each turtle has properties:
     - `spice`: Tracks its energy level.
     - `target`: The patch it aims to reach for resources.
     - `p-association`: Probability of forming links with other turtles.
     - `cap-association`: Capacity for maintaining connections.

2. **Environment (Patches):**
   - Patches hold resources (`ressource`) and can act as attractors (`attractor?`).
   - Attractors are rich patches that turtles can seek and exploit.

3. **Global Variables:**
   - Track system-wide metrics.

4. **Processes:**
   - **Setup:** Initializes turtles, patches, and global settings.
   - **Target and Movement:**
     - Turtles seek attractors or wander randomly if no attractor is nearby.
     - Turtles establish or dissolve connections with others based on `p-association` and `cap-association`.
   - **Resource Consumption:** 
     - Turtles consume resources on attractor patches to replenish food.
     - If a patch’s resources are depleted, it ceases to be an attractor.
   - **Mutation and Growth:**
     - Turtles may mutate their properties (`p-association`, `cap-association`) or divide when sufficiently nourished.
   - **Crisis Management:**
     - Adjusts environmental growth rates and resource levels based on defined crises (`crisis-I` or `crisis-II`).
   - **Network Maintenance:**
     - Tracks metrics.

5. **End Condition:**
   - The simulation stops when no turtles remain.

## HOW TO USE IT

1. **Setting Up:**
   - Adjust the sliders or input fields for initial settings, including:
     - `num-nodes`: Number of turtles.
     - `initial-food`: Starting energy for turtles.
     - `initial-p` and `initial-cap`: Initial association probabilities and capacities.
     - `growth-rate`, `wealth`, and `max-attractors`: Parameters controlling patch behavior.

2. **Starting the Simulation:**
   - Click the **Setup** button to initialize the environment and agents.
   - Press **Go** to start the simulation.

3. **Observing the Model:**
   - Watch as turtles move, interact, and gather resources.
   - Monitor plots and global variables to track system behavior:
     - **Goods:** Tracks the total resources consumed.
     - **Average Properties:** View trends in `p-association`, `cap-association`
     - **Network Properties:** Tracks the adjacency list of the network.


4. **Experimenting:**
   - Enable or disable crisis modes to observe the impact of environmental stressors on the system.
   - Adjust mutation rate (`mutation-rate`) and bad mutation probability (`bad-mutation`) to explore evolutionary dynamics.
   - Test different initial conditions for network formation and resource availability.

5. **Analyzing Results:**
   - Use the simulation's metrics and visualization tools to analyze the ecosystem's stability, resource distribution, and network dynamics.
   - Experiment with different parameter settings to study emergent behaviors and resilience under stress.
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="network_exploitation_0" repetitions="3" runMetricsEveryStep="false">
    <preExperiment>set settings true</preExperiment>
    <setup>setup</setup>
    <go>go</go>
    <timeLimit steps="10001"/>
    <metric>values</metric>
    <runMetricsCondition>ticks = 10000</runMetricsCondition>
    <enumeratedValueSet variable="settings">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="wealth">
      <value value="10000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="growth-rate">
      <value value="50"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="max-attractors">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="num-nodes">
      <value value="20"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="wander">
      <value value="90"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="sight">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="initial-spice">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="initial-cap">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="initial-p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="speed">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mutation-rate">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="bad-mutation">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="minor-switch">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="crisis-duration">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="switch">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="time-limit">
      <value value="10000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="neutral">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dispersion">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="concentration">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
</experiments>
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
