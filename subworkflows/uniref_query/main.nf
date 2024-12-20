process downloadProteins {

    // where to store the results and in which way
    storeDir(params.OUTPUT)

    label 'geneidx'
    // show in the log which input file is analysed
    tag "Downloading proteins ${prot_filename}"

    input:
    tuple val(id), val(text_desc)

    output:
    tuple val(id), path ("${prot_filename}.fa.gz")

    script:
    (prot_desc, prot_filename, prot_query ) = (text_desc =~ /([A-Za-z\d\.\+]+)\s(.*)/)[0]
    """
    #!/usr/bin/env python3

    import requests, os

    print(" Downloading ${prot_filename}.fa.gz ")
    with requests.get("${prot_query}", stream=True) as request:
        request.raise_for_status()
        with open('${prot_filename}.fa.gz', 'wb') as f:
            for chunk in request.iter_content(chunk_size=2**20):
                f.write(chunk)
    """
}

process getUniRefQuery {

    // indicates to use as a label the value indicated in the parameter
    label 'geneidx'

    errorStrategy 'retry'
    maxRetries 3

    // show in the log which input file is analysed
    tag "${id} ${taxid}"

    input:
    tuple val(id), val(taxid)

    output:
    tuple val(id), stdout
    
    script:
    upper_lim_proteins = params.proteins_upper_lim
    lower_lim_proteins = params.proteins_lower_lim
    """
    #!/usr/bin/env python3

    sp_taxon_id = ${taxid}

    lower_lim = ${lower_lim_proteins}
    upper_lim = ${upper_lim_proteins}

    identity = 0.9
    ini_clu_size = 24
    clu_size = ini_clu_size

    max_iterations = 30


    import requests
    from lxml import etree

    def parse_taxon_mod(xml):
        root = etree.fromstring(xml)
        species = (root[0].attrib["rank"], root[0].attrib["taxId"])
        lineage = []
        for taxon in root[0]:
            if taxon.tag == 'lineage':
                lin_pos = 0
                for node in taxon:
                    if "rank" in node.attrib.keys():
                        lineage.append( (node.attrib["rank"], node.attrib["taxId"]) )
                    else:
                        lineage.append((lin_pos, node.attrib["taxId"]))
                    lin_pos += 1

        lineage.insert(0,species)
        return lineage



    response = requests.get(f"https://www.ebi.ac.uk/ena/browser/api/xml/{sp_taxon_id}?download=false")


    lineage_l = parse_taxon_mod(response.content)
    rank_l = []
    taxid_l = []
    for a, b in lineage_l:
        rank_l.append(a)
        taxid_l.append(b)

    if rank_l.index("class"):
        pos_class = rank_l.index("class")
    else:
        pos_class = len(rank_l)//2

    taxon = taxid_l[pos_class]
    # print(taxon)


    # build initial query
    search_type = "search"
    format_type = "list"
    initial_query = "https://rest.uniprot.org/uniref/{}?format={}".format(search_type, format_type)


    # define parameters controlling the loop
    i=0
    in_range = False


    while not in_range and i < max_iterations:
        query = initial_query + "&query=(taxonomy_id:{})%20AND%20(identity:{})%20AND%20(count:[{}%20TO%20*])".format(taxon, identity, clu_size)
        r = requests.get(query)

        # if we have more proteins than the minimum required
        if lower_lim <= int(r.headers["X-Total-Results"]):

            # check if we are inside the target range of proteins
            if int(r.headers["X-Total-Results"]) <= upper_lim:
                in_range = True

            # if we are above the target range, increase the cluster size required, this will reduce the number of proteins
            elif clu_size <= 50:
                clu_size += 3

            # if we already have a very big cluster size, go one taxonomic rank lower to reduce the diversity of proteins available
            else :
                # get one taxonomic rank lower
                pos_class = pos_class - 1
                taxon = taxid_l[pos_class]
                clu_size = ini_clu_size

        # as we don't reach the minimum number of proteins, we need to get less stringent in terms of cluster size
        elif clu_size >= 6:
            clu_size -= 3

        # if even when reducing cluster size a lot, we don't get enough proteins, let's get one taxonomic rank higher.
        else:
            # get one taxonomic rank higher
            pos_class = pos_class + 1
            taxon = taxid_l[pos_class]
            clu_size = ini_clu_size

        # update i as we want to have a maximum number of queries
        # do we want this maximum number??
        i += 1


    # this is included to have a solution for the worst case scenario
    if not in_range:
        taxon = "2759" # eukaryotes taxid
        clu_size = 60  # change appropriately


    search_type = "stream"
    format_type = "fasta"
    initial_query = "https://rest.uniprot.org/uniref/{}?format={}".format(search_type, format_type)
    query = initial_query + "&compressed=true&query=(taxonomy_id:{})%20AND%20(identity:{})%20AND%20(count:[{}%20TO%20*])".format(taxon, identity, clu_size)
    filename = "UniRef{}.{}.{}+".format(int(identity * 100), taxon, clu_size)

    content_to_write = filename + "\t" + query
    print(content_to_write)
    """
}

workflow uniref_query {
    
    take:
    meta

    main:
    uniref_proteins  = getUniRefQuery(meta) | downloadProteins
    
    emit:
    uniref_proteins
}
