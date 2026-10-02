--!strict
-- Types partagés entre le serveur et les clients.

export type LonLat = {
	lon: number,
	lat: number,
}

export type City = {
	name: string,
	lon: number,
	lat: number,
	isCapital: boolean?, -- capitale d'un pays
	isMain: boolean?, -- ville principale d'un territoire (ex. Cayenne)
	-- ni l'un ni l'autre : simple centre d'une région (point de repère des armées, non dessiné)
}

-- Un pays (joueur ou IA)
export type Country = {
	id: string, -- code ISO à 3 lettres, ex. "FRA"
	name: string, -- nom affiché
	color: Color3, -- couleur sur la carte
	capital: City,
}

-- Liaison entre deux régions voisines
export type NeighborLink = {
	region: string,
	bySea: boolean, -- vrai si la liaison se fait par la mer
}

-- Une région de la carte
export type Region = {
	id: string,
	name: string,
	geometry: string, -- clé du contour dans Config/MapGeometry
	startOwner: string, -- pays propriétaire au début de la partie
	city: City?, -- capitale, ville principale ou centre de la région (là où stationnent les armées)
	port: LonLat?, -- point en mer près de la côte (régions côtières seulement) : mouillage des flottes
	neighbors: { NeighborLink },
}

-- Ressource échangeable (pétrole, acier...)
export type Resource = {
	id: string,
	name: string,
	icon: string, -- émoji affiché dans l'interface
	base: boolean, -- vrai si produite directement par les régions (sinon fabriquée en usine)
	use: string, -- à quoi elle sert
}

-- Production d'une région ou d'un pays : ressource -> unités par cycle
export type Production = { [string]: number }

-- Chaîne de montagnes décorative (liste de points lon/lat)
export type MountainRange = {
	name: string,
	height: number, -- hauteur max des sommets (studs)
	points: { LonLat },
}

return nil
