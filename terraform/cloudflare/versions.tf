terraform {
  required_version = ">= 1.6.0" # import blocks need 1.5+; 1.6 for stable validate output

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  # Token read from CLOUDFLARE_API_TOKEN; never stored in this repo.
}
