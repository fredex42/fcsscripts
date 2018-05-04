require 'elasticsearch'
require 'nokogiri'
require 'awesome_print'
require 'json'
require 'trollop'

class FinalCutServerMetaEntry
  attr_accessor :metadata
  attr_accessor :address
  def initialize(entry)
    @metadata = {}
    entry.xpath("value[@id='METADATA']/values/value").each {|field|
      @metadata[field['id']]=field.children.select {|c| not c.text? }.map {|c| c.text }
    }
    @complete = entry.xpath("value[@id='COMPLETE']/bool").text
    @address = entry.xpath("value[@id='ADDRESS']/string").text
  end

  def to_hash(server_name)
    {
      'ADDRESS'=>@address,
      'server'=>server_name,
      'COMPLETE'=>@complete
    }.merge(@metadata)
  end
end


##START MAIN
opts = Trollop::options do
  opt :input, "XML dump to import", :type=>:string
  opt :elasticsearch, "Elasticsearch to connect to", :type=>:string, :default=>"localhost:9200"
  opt :index_name, "Index to write to", :type=>:string, :default=>"fcs_test"
  opt :doc_type, "Document type name to create", :type=>:string, :default=>"meta"
  opt :original_server, "Server that the data dump came from", :type=>:string, :default=>"test-host"
end

client = Elasticsearch::Client.new(host: opts.elasticsearch)
healthdata = client.cluster.health
if healthdata["status"]!="green"
  puts "ERROR: Elasticsearch cluster #{healthdata["cluster_name"]} at #{opts.elasticsearch} is not GREEN, it is #{healthdata["status"]}"
  exit(1)
else
  puts "INFO: Connected to #{healthdata["cluster_name"]} at #{opts.elasticsearch}"
end

if ! client.indices.exists? index: opts.index_name
  puts "WARNING: index #{opts.index_name} does not exist, creating"
  client.indices.create index: opts.index_name
end

open opts.input do |f|
  puts "Reading in #{opts.input}"
  xmldata = Nokogiri::XML(f.read)

  puts "Processing #{opts.input}"
  to_dump = []

  xmldata.children.xpath('values').each do |entry|
    to_dump << FinalCutServerMetaEntry.new(entry)
    if to_dump.length>100
      puts "Dumping 100 records...."
      result = client.bulk(body: to_dump.map { |entry|
        {
          "index"=>{
            "_index"=>opts.index_name,
            "_type"=> opts.doc_type,
            "_id"=> "#{opts.original_server}-#{entry.metadata['ASSET_NUMBER'][0]}",
            "data"=>entry.to_hash(opts.original_server)
          }
        }
      })
      if result['errors']
        ap result
        break
      end
      to_dump = []
    end
  end

  puts "Dumping last #{to_dump.length} records...."

  result = client.bulk(body: to_dump.map { |entry|
    {
      "index"=> {
        "_index"=>opts.index_name,
        "_type"=> opts.doc_type,
        "_id"=> "#{opts.original_server}-#{entry.metadata['ASSET_NUMBER'][0]}",
        "data"=>entry.to_hash(opts.original_server)
      }
    }
  })
  if result['errors']
    ap result
    exit 1
  end
  ap result

  #ap entries
  # entries.each do |entry|
  #   #ap entry.name
  #   processed = FinalCutServerMetaEntry.new(entry)
  #   p processed.to_json("test")
  #   #p "----------------------------"
  # end


  #print JSON.generate(entries.map {|e| FinalCutServerMetaEntry.new(e).to_hash("temp")})
end
