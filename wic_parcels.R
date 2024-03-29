  #Associate the work order IDs with parcel facility IDs
  #Written by: Farshad Ebrahimi- 4/22/2022.


## Section 1: Gathering nonspatial data

    library(DBI)
    library(RPostgreSQL)
    library(RPostgres)
    library(odbc)
    library(dplyr)
    library(sf)
    

  # connect to the GIS DB to get parcel polygon
  
    GISDB <- dbConnect(odbc(),
                           Driver = "ODBC Driver 17 for SQL Server",
                           Server = "PWDGISSQL",
                           Database = "GISDATA",
                           uid = Sys.getenv("gis_uid"),
                           pwd= Sys.getenv("gis_pwd"))
  
    Parcels_Frame <- dbGetQuery(GISDB, "SELECT * from GISDATA.GISAD.PWD_PARCELS")
    
    Parcels_facility_id <- select(Parcels_Frame, FACILITYID)
    
    Parcels_Address_id <- select(Parcels_Frame, ADDRESS, FACILITYID)
  
    PARCELS_SPATIAL <- st_read(dsn = "\\\\pwdoows\\oows\\Watershed Sciences\\GSI Monitoring\\09 GIS Data\\PWD_PARCELS ", layer = "PWD_PARCELS")
    
    st_crs(PARCELS_SPATIAL) = 2272
  
  # Connect to MARS DB and get the workorderid, comments and associated info
    
    con <- dbConnect(odbc(), dsn = "mars_data")
    
    WORKORDER_ID <- dbGetQuery(con, "SELECT * from fieldwork.wic_workorders")
    
    WORKORDER_CM <- dbGetQuery(con, "SELECT * from fieldwork.wic_comments")
    
  # Remove {} from facilityid in cityworks 
    ###Taylor says: You can do this in one go with a capture group
    ###Regex = in: a literal {, followed by a capture group containing 0 or more characters, followed by a literal }
    ###Regex = out: The first capture group
    
    WORKORDER_ID$facility_id<-gsub("\\{(.*)\\}","\\1",as.character(WORKORDER_ID$facility_id))
    PARCELS_SPATIAL$FACILITYID<-gsub("\\{(.*)\\}","\\1",as.character(PARCELS_SPATIAL$FACILITYID))
    


## Section 2: Matching by facility ID
    
  # Inner join the workorderid and Parcels_Address_id ON facility ID
    
    WOID_FACID_Match <- inner_join (WORKORDER_ID, Parcels_Address_id  , by = c("facility_id"="FACILITYID"))
   
   
  # Get FIRST OUTPUT BASED ON FACILITYID MATCH STORED IN WOID_FAC_UNIQ_REL
   
    WOID_FAC_UNIQ_REL <- select(WOID_FACID_Match, workorder_id, location, facility_id)
  
  # Remove the rows that we matched based on the facilityid from the cityworks table 
     
    WORKORDER_ID <- anti_join(WORKORDER_ID, WOID_FACID_Match, by = "workorder_id")
    
  # Remove the rows that were matched from the Parcels_Address_id table
    
    Parcels_Address_id <-anti_join(Parcels_Address_id, WOID_FACID_Match, by = c("FACILITYID"="facility_id") )
    
  # drop the facility id from workorderid as these ids are not meaningful 
    
    WORKORDER_ID_Location <-  select(WORKORDER_ID, -facility_id)
    
    
## Section 3: Matching by address
    

  # Inner join the  WORKORDER_ID_Location with Parcels_Address_id to extract the facility id
   
    WO_ID_ADDRESS_MATCH <- inner_join(WORKORDER_ID_Location,Parcels_Address_id,by = c("location" = "ADDRESS"))

  # GET SECOND OUTPUT BASED ON FACILITYID MATCH STORED IN WOID_FAC_UNIQ_Add_REL )  

    WOID_FAC_UNIQ_Add_REL <- WO_ID_ADDRESS_MATCH  %>% select(workorder_id, location, facility_id = FACILITYID)  
   
  # Remove the rows that we were matched based on the address from the cityworkstable 
   
    WORKORDER_ID <- anti_join(WORKORDER_ID, WO_ID_ADDRESS_MATCH, by = "workorder_id")
    
  # Remove the rows that were matched from the Parcels_Address_id table
    
    Parcels_Address_id <-anti_join(Parcels_Address_id, WO_ID_ADDRESS_MATCH, by = "FACILITYID" ) 
    
## Section 4: Gathering spatial data
    
  # Build the spatial object from the XY coordinates in Cityworks
   
    xy_coor <-  c(WORKORDER_ID[,"wo_xcoordinate"],WORKORDER_ID[,"wo_ycoordinate"])

    mat_coor <- matrix(data = xy_coor, ncol = 2) %>% na.omit
  
    WO_SPATIAL <- mat_coor |> 
       as.matrix() |> 
       st_multipoint() |> 
       st_sfc() |> 
       st_cast('POINT')
     
    st_crs(WO_SPATIAL) <- 2272
     
  # Intersect the Parcel polygons and the points
     
     WO_PARC_INTERSECT <- st_intersects(WO_SPATIAL, PARCELS_SPATIAL )
     
## Section 5: Matching WICs to parcels by geoprocessing
     
 
  # Get the index of intersecting XY coordinates and Parcel polygons
     
     
     Index_WO <- NULL
     
     Index_Parcel <- NULL
     
      for(i in 1:length(WO_PARC_INTERSECT)) {
       
          temp <- WO_PARC_INTERSECT[[i]]
       
            if (length(temp) > 0) {

            WO <- rep(i, length(temp))
            
            Parcel <- temp

            Index_WO <- c(Index_WO, WO )
            
            Index_Parcel <- c(Index_Parcel, Parcel ) 
            
            }
                                             
       }
     
     
  # attach the XY coordinate to the Parcel frame to create COORD_MATCHED_TABLE
     
     mat_coor <- data.frame (mat_coor)
     
     names(mat_coor) <- c("wo_xcoordinate","wo_ycoordinate")
     
     WO_MATCHED_XY <- mat_coor[Index_WO, ]
     
     Parcel_Matched_Polyg <- PARCELS_SPATIAL[Index_Parcel, ]
     
     COORD_MATCHED_TABLE <- cbind(Parcel_Matched_Polyg,WO_MATCHED_XY)
     
  # Get workorderid, address, and facilityid (Third output is stored in WOID_Based_XY )
     
     WOID_Based_XY<- WORKORDER_ID %>% select(workorder_id, wo_initiatedate, location, wo_xcoordinate, wo_ycoordinate) %>% inner_join(COORD_MATCHED_TABLE, by = c("wo_xcoordinate" = "wo_xcoordinate", "wo_ycoordinate" = "wo_ycoordinate")) %>% select(workorder_id, location = ADDRESS, facility_id = FACILITYID) 
     
  # union the matching tables-Final output is in FACID_ADD_XY
   
     FACID_ADD <- union_all (WOID_FAC_UNIQ_REL,WOID_FAC_UNIQ_Add_REL)
    
     FACID_ADD_XY <- union_all (FACID_ADD, WOID_Based_XY)
    
     wic_parcels <- unique(FACID_ADD_XY)
     
     
  # Add the workorder date 
     
     WORKORDER_ID <- dbGetQuery(con, "SELECT * from fieldwork.wic_workorders")
     
     WORK_DATE <- WORKORDER_ID %>% select(workorder_id, wo_initiatedate)
     
     wic_parcels <- inner_join(wic_parcels, WORK_DATE, by = "workorder_id") %>% select(workorder_id, location, facility_id, wo_initiatedate)
     
     wic_parcels <- inner_join(wic_parcels, Parcels_Frame, by=c("facility_id"="FACILITYID")) %>% select(workorder_id, ADDRESS, facility_id, wo_initiatedate)
     
     names(wic_parcels) <- c("workorder_id","location","facility_id", "wo_initiatedate")
    
     
## Section 6: Writing results to DB
    
     con <- dbConnect(odbc(), dsn = "mars_data")
    
     dbWriteTable (con, SQL("fieldwork.wic_parcels"),wic_parcels,append= TRUE, row.names = FALSE)
     
     dbDisconnect(GISDB)
     dbDisconnect(con)
     
     