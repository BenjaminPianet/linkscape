# linkscape

Ce modèle explore l’évolution d’un réseau d’agents dans un contexte de gestion de ressources communes. Les agents cherchent à survivre en consommant de la nourriture dispersée dans l’environnement.

Nous suivons la structure du réseau d’agents, où deux agents liés sont considérés comme voisins. Les voisins peuvent et vont communiquer entre eux s’ils découvrent de la nourriture. Un agent n’ayant pas trouvé de nourriture se déplacera vers un voisin qui en a trouvé, si un tel voisin existe. Sinon, l’agent se déplacera de manière aléatoire jusqu’à ce qu’il trouve de la nourriture ou ne meure.

Dans ce modèle, un réseau d’agents fortement connecté favorise un comportement coopératif marqué, tandis qu’un réseau faiblement connecté reflète une dynamique plus compétitive. À chaque pas de temps, chaque agent perd une quantité fixe de nourriture et meurt si son niveau de nourriture atteint zéro. Les agents peuvent également ajuster leur connectivité (c’est-à-dire leur probabilité de former des liens avec d’autres agents) avec une probabilité de mutation fixe. De plus, ils peuvent se dupliquer s’ils accumulent suffisamment de nourriture pour dépasser un seuil déterminé.


<br>

#### Une première simulation sur 40 000 itérations de notre modèle. Les ressources sont peu concentrées pendant les 20 000 premières itérations et très concentrées pendant les 20 000 dernières.

<p align="center">
  <img src="gifs/output1.gif" alt="GIF">
</p>

<br><br>
#### Une seconde simulation identique à la première mais avec des ressources très concentrées pendant les 20 000 premières itérations et peu concentrées pendant les 20 000 dernières.

<p align="center">
  <img src="gifs/output2.gif" alt="GIF">
</p>

Nous observons que la coopération émerge rapidement lorsque les ressources sont très concentrées alors que des comportements compétitifs émergent lorsque la ressource est peu concentrée.
De plus, malgré la transition dans les niveaux de concentration de la ressource, le système s'adapte et retrouve un régime stable après une phase de perturbation brève.
