require "pagy/extras/overflow"
require "pagy/extras/limit"
Pagy::DEFAULT[:limit] = 20
Pagy::DEFAULT[:limit_max] = 100
Pagy::DEFAULT[:limit_param] = :per_page
Pagy::DEFAULT[:overflow] = :empty_page
require "pagy/extras/array"
